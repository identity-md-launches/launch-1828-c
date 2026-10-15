// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardLending} from "src/CardLending.sol";
import {CardOracle} from "src/CardOracle.sol";
import {Guarded} from "src/Guarded.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Edges introduced by the revised implementation: the guardian seat that follows ownership, the
/// borrower's APR cap on renewal, rounded-up interest, and the lazily synced auction book behind pool NAV.
contract CardRevisionEdgesTest is Fixture {
    uint256 internal constant PAR_WINDOW = 24_685; // floor(2000 * 86400 / 7000)

    function test_guardianAppointedDuringNominationSurvivesAcceptanceAndOldOwnerLosesPause() public {
        address[3] memory targets = [address(pool), address(oracle), address(lending)];
        for (uint256 i; i < targets.length; ++i) {
            Guarded g = Guarded(targets[i]);
            g.transferOwnership(bob);
            g.setGuardian(guardian);
            vm.prank(bob);
            g.acceptOwnership();
            assertEq(g.guardian(), guardian, "a seat given away before acceptance does not move");
            vm.expectRevert(Guarded.NotGuardian.selector);
            g.pause();
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
            g.setGuardian(address(this));
            vm.prank(guardian);
            g.pause();
            assertTrue(g.paused());
        }
    }

    function test_nomineeAlreadySeatedAsGuardianKeepsSeatAndOutgoingOwnerCannotPause() public {
        lending.setGuardian(bob);
        lending.transferOwnership(bob);
        vm.prank(bob);
        lending.acceptOwnership();
        assertEq(lending.guardian(), bob);
        assertEq(lending.owner(), bob);
        vm.expectRevert(Guarded.NotGuardian.selector);
        lending.pause();
        vm.prank(bob);
        lending.pause();
        vm.prank(bob);
        lending.unpause();
        // A second hand-over moves the seat again only because the current owner also holds it.
        vm.prank(bob);
        lending.transferOwnership(alice);
        vm.prank(alice);
        lending.acceptOwnership();
        assertEq(lending.guardian(), alice);
        vm.expectRevert(Guarded.NotGuardian.selector);
        vm.prank(bob);
        lending.pause();
    }

    function test_extendAcceptsCapEqualToRateAndRefusesOnePointBelowWithoutStateChange() public {
        uint256 id = borrow(400e6);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        deliverPrice(1000);
        lending.setAPR(1199);
        bytes32 before = keccak256(abi.encode(lending.loan(id), lending.rateWeight(), lending.interestNumerator()));
        vm.expectRevert(CardLending.RateAboveLimit.selector);
        vm.prank(alice);
        lending.extend(id, 1198);
        assertEq(keccak256(abi.encode(lending.loan(id), lending.rateWeight(), lending.interestNumerator())), before);
        vm.prank(alice);
        lending.extend(id, 1199);
        assertEq(getLoan(id).aprBps, 1199);
        assertEq(lending.rateWeight(), 400e6 * 1199);
        // A zero cap only works once the owner has set a zero rate.
        vm.warp(vm.getBlockTimestamp() + 1);
        deliverPrice(1000);
        vm.expectRevert(CardLending.RateAboveLimit.selector);
        vm.prank(alice);
        lending.extend(id, 0);
        lending.setAPR(0);
        vm.prank(alice);
        lending.extend(id, 0);
        assertEq(getLoan(id).aprBps, 0);
        assertEq(lending.rateWeight(), 0);
    }

    function test_extendChecksPrincipalAgainstLTVAfterInterestIsPaid() public {
        // 45% of $1000 is 450e6; 30 days of 12% interest at maturity minus one second pushes gross debt past it.
        uint256 id = borrow(450e6);
        vm.warp(getLoan(id).maturity - 1);
        deliverPrice(1000);
        uint256 interest = lending.interestOf(id);
        assertGt(450e6 + interest, 450e6, "interest is owed");
        vm.prank(alice);
        lending.extend(id, 1200);
        assertEq(lending.debtOf(id), 450e6, "renewed at exactly the cap once interest is paid");
        // One dollar less collateral and the same principal is refused.
        vm.warp(vm.getBlockTimestamp() + 1);
        deliverPrice(999);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.extend(id, 1200);
    }

    function test_oneSecondOfInterestOnOneUnitRoundsUpToOneUnit() public {
        lending.setAPR(1);
        uint256 id = borrow(2);
        assertEq(lending.interestOf(id), 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(lending.interestOf(id), 1, "any positive accrual owes at least one base unit");
        assertEq(lending.debtOf(id), 3);
        assertEq(lending.totalDebt(), 3);
        vm.prank(alice);
        lending.repay(id);
        assertEq(usdc.balanceOf(address(pool)), 10_000e6 + 2, "pool collects principal and the rounded-up unit");
        assertEq(pool.totalAssets(), 10_000e6 + 1, "one unit of yield; the fee unit stays reserved");
        assertEq(lending.totalDebt(), 0);
    }

    function test_aggregateInterestRoundsOnceWhileLoansRoundIndividually() public {
        lending.setAPR(1);
        uint256 first = borrow(2);
        uint256 otherToken = nft.mint(alice, cardMetadata("second tiny loan"));
        vm.prank(alice);
        uint256 second = lending.borrow(otherToken, 2);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(lending.debtOf(first) + lending.debtOf(second), 6);
        assertEq(lending.totalDebt(), 5, "aggregate rounds the summed numerator once");
        (uint256 receivable,) = lending.netReceivable();
        assertEq(receivable, 5);
        uint256 nav = pool.totalAssets();
        assertEq(pool.reserve(), 2, "one fee unit per loan");
        vm.startPrank(alice);
        lending.repay(first);
        lending.repay(second);
        vm.stopPrank();
        assertEq(
            usdc.balanceOf(address(pool)), 10_000e6 + 4, "settlement collects six units against a receivable of five"
        );
        assertEq(pool.totalAssets(), nav, "the extra unit is not a gain a lender could time");
        assertEq(pool.reserve(), 3, "the unit the aggregate never carried is held back as reserve");
        assertEq(pool.coveredReserve(), 0);
    }

    function test_auctionMarkAtEveryPhaseBoundary() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 start = getLoan(id).auctionStartedAt;
        uint256 cash = usdc.balanceOf(address(pool)) - pool.reserve();
        _assertMark(id, start, 400e6, cash, "at open");
        _assertMark(id, start + PAR_WINDOW, 400e6, cash, "last par second");
        vm.warp(start + PAR_WINDOW + 1);
        assertLt(lending.auctionMark(id), 400e6, "first descent second is below par");
        _assertMark(id, start + 12 hours, 340e6, cash, "midpoint");
        vm.warp(start + 1 days - 1);
        uint256 lastDescentQuote = lending.auctionPrice(id);
        assertGt(lastDescentQuote, 200e6);
        _assertMark(id, start + 1 days - 1, lastDescentQuote, cash, "last descent second");
        _assertMark(id, start + 1 days, 200e6, cash, "floor");
        vm.warp(start + 1 days + 1);
        assertLt(lending.auctionMark(id), 200e6, "first second past the floor is already written down");
        assertEq(lending.auctionPrice(id), 200e6, "the sale price stays at the floor");
        _assertMark(id, start + 36 hours, 100e6, cash, "half written down");
        // 400e6 * 1 second / 2 days, rounded up: the last marked second still carries one small positive mark.
        _assertMark(id, start + 2 days - 1, 2315, cash, "last marked second");
        _assertMark(id, start + 2 days, 0, cash, "write-off");
        _assertMark(id, start + 400 days, 0, cash, "stays written off");
        assertEq(lending.auctionPrice(id), 200e6, "write-off does not change the sale price");
    }

    function test_repayAndSaleAfterWriteOffLeaveNoResidualBookEntries() public {
        lending.setAPR(0);
        uint256 first = borrow(400e6);
        uint256 otherToken = nft.mint(alice, cardMetadata("second written-off loan"));
        vm.prank(alice);
        uint256 second = lending.borrow(otherToken, 300e6);
        vm.warp(getLoan(second).maturity);
        lending.liquidate(first);
        lending.liquidate(second);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        assertEq(receivable, 0);
        assertEq(shortfall, 700e6);
        assertEq(pool.totalAssets(), 10_000e6 - 700e6 + 7e6, "only the 7e6 reserve counts against the loss");
        assertEq(pool.coveredReserve(), 7e6);
        vm.prank(alice);
        lending.repay(first);
        // The full repayment of a loan carried at zero is held back entirely; the counted 7e6 still backs the second.
        assertEq(pool.reserve(), 407e6);
        assertEq(pool.coveredReserve(), 7e6);
        assertEq(pool.totalAssets(), 10_000e6 - 700e6 + 7e6, "repayment moves no NAV");
        vm.prank(bob);
        lending.buy(second, 150e6, bob);
        assertEq(lending.frozenDebt(), 0);
        assertEq(
            lending.parDebt() + lending.descentDebt() + lending.descentWeight() + lending.decayDebt()
                + lending.decayWeight(),
            0
        );
        (receivable, shortfall) = lending.netReceivable();
        assertEq(receivable + shortfall, 0);
        // The counted 7e6 is spent on the second loan; its 150e6 floor proceeds are held back for later losses.
        assertEq(pool.reserve(), 400e6 + 150e6, "recoveries above a zero mark become reserve");
        assertEq(pool.coveredReserve(), 0, "nothing left to cover");
        assertEq(pool.totalAssets(), 10_000e6 - 700e6 + 7e6, "lenders carried the loss on the curve, not at the sale");
        assertEq(pool.availableLiquidity(), 10_000e6 - 700e6 + 7e6, "NAV is all cash once the book is empty");
        assertEq(lending.auctionQueueLength(), 2, "closed entries remain in the queue but carry nothing");
        lending.syncAuctions();
        assertEq(lending.parHead(), 2);
        assertEq(lending.descentHead(), 2);
        assertEq(lending.decayHead(), 2);
    }

    function test_laterAuctionCannotBeAdvancedPastEarlierOneByOutOfOrderClosure() public {
        lending.setAPR(0);
        uint256 first = borrow(400e6);
        uint256 otherToken = nft.mint(alice, cardMetadata("staggered auction"));
        vm.prank(alice);
        uint256 second = lending.borrow(otherToken, 100e6);
        vm.warp(getLoan(first).maturity);
        lending.liquidate(first);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        lending.liquidate(second);
        // First is mid-descent (340e6), second is at par (100e6). Close the earlier entry first, then
        // read the later one through the projection at every phase it passes through.
        vm.prank(alice);
        lending.repay(first);
        (uint256 receivable,) = lending.netReceivable();
        assertEq(receivable, 100e6);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        (receivable,) = lending.netReceivable();
        assertEq(receivable, lending.auctionPrice(second), "second alone follows its own clock");
        assertEq(receivable, 85e6);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        (receivable,) = lending.netReceivable();
        assertEq(receivable, 50e6);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (receivable,) = lending.netReceivable();
        assertEq(receivable, 0);
        vm.prank(bob);
        lending.buy(second, 50e6, bob);
        (receivable,) = lending.netReceivable();
        assertEq(receivable, 0);
        assertEq(lending.frozenDebt(), 0);
    }

    function test_futureIssuedAtWithinToleranceSettlesButCannotBorrowUntilClockCatchesUp() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes);
        a.expiresAt = a.issuedAt + 1 days;
        _callback(id, a, sign(a));
        vm.expectRevert(CardOracle.StalePrice.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 1e6);
        vm.warp(vm.getBlockTimestamp() + 5 minutes - 1);
        vm.expectRevert(CardOracle.StalePrice.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 1e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        uint256 loanId = lending.borrow(tokenId, 1e6);
        assertEq(getLoan(loanId).priceIssuedAt, a.issuedAt);
        // The next request cannot be answered with an issuance one second beyond the tolerance.
        bytes32 next = ask();
        a = attestation(1001);
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        a.expiresAt = a.issuedAt + 1 days;
        bytes memory signature = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        _callback(next, a, signature);
        assertTrue(oracle.request(next).pending);
    }

    function _assertMark(uint256 id, uint256 at, uint256 expected, uint256 cash, string memory label) internal {
        vm.warp(at);
        assertEq(lending.auctionMark(id), expected, string.concat("mark ", label));
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        assertEq(receivable, expected, string.concat("receivable ", label));
        assertEq(shortfall, 400e6 - expected, string.concat("shortfall ", label));
        uint256 cover = shortfall < pool.reserve() ? shortfall : pool.reserve();
        assertEq(pool.totalAssets(), cash + expected + cover, string.concat("NAV ", label));
    }
}
