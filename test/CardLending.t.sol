// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardLending} from "../src/CardLending.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {CardPool} from "../src/CardPool.sol";
import {MockCardNFT} from "../src/MockCardNFT.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract AuctionReceiver is IERC721Receiver {
    CardLending public lending;
    uint256 public loanId;
    bool public reentryBlocked;
    bool public reject;

    constructor(CardLending l, uint256 id, bool reject_) {
        lending = l;
        loanId = id;
        reject = reject_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!reject, "reject card");
        try lending.buy(loanId, type(uint256).max, address(this)) {
            reentryBlocked = false;
        } catch {
            reentryBlocked = true;
        }
        return this.onERC721Received.selector;
    }
}

contract CardLendingTest is Fixture {
    function test_borrowCustodiesNFTPaysNetAndReservesFee() public {
        uint256 beforeBalance = usdc.balanceOf(alice);
        uint256 beforeNAV = pool.totalAssets();
        uint256 id = borrow(450e6);
        CardLending.Loan memory l = getLoan(id);
        assertEq(nft.ownerOf(tokenId), address(lending));
        assertEq(usdc.balanceOf(alice), beforeBalance + 445_500_000);
        assertEq(pool.reserve(), 4_500_000);
        assertEq(pool.availableLiquidity(), 9550e6);
        assertEq(pool.totalAssets(), beforeNAV);
        assertEq(lending.totalDebt(), 450e6);
        assertEq(lending.collateralLoan(tokenId), id);
        assertEq(l.borrower, alice);
        assertEq(l.classId, cardClass);
        assertEq(l.maturity, block.timestamp + 30 days);
        assertEq(l.aprBps, 1200);
        assertEq(uint256(l.state), uint256(CardLending.State.Active));
    }

    function test_borrowRejectsNoPriceStalePriceZeroAndAboveLTV() public {
        vm.expectRevert(CardOracle.StalePrice.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 1e6);
        deliverPrice(1000);
        vm.expectRevert(CardLending.InvalidAmount.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 0);
        vm.expectRevert(CardLending.InvalidAmount.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 1);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 450e6 + 1);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(CardOracle.StalePrice.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 400e6);
    }

    function test_borrowRejectsNonOwnerNoApprovalAndInsufficientLiquidity() public {
        deliverPrice(1000);
        vm.expectRevert(CardLending.NotBorrower.selector);
        vm.prank(bob);
        lending.borrow(tokenId, 400e6);
        vm.prank(alice);
        nft.setApprovalForAll(address(lending), false);
        vm.expectRevert();
        vm.prank(alice);
        lending.borrow(tokenId, 400e6);
        vm.prank(alice);
        nft.setApprovalForAll(address(lending), true);
        vm.prank(lender);
        pool.withdraw(9900e6, lender, lender);
        vm.expectRevert(CardPool.InsufficientLiquidity.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 400e6);
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(lending.activePrincipal(), 0);
        assertEq(lending.nextLoanId(), 1);
    }

    function test_interestLinearAPRIsSnapshottedAndAccruesAfterMaturity() public {
        uint256 id = borrow(400e6);
        lending.setAPR(5000);
        vm.warp(block.timestamp + 15 days);
        assertEq(lending.interestOf(id), Math.ceilDiv(uint256(400e6) * 1200 * 15 days, 10_000 * 365 days));
        vm.warp(block.timestamp + 30 days);
        assertEq(lending.interestOf(id), Math.ceilDiv(uint256(400e6) * 1200 * 45 days, 10_000 * 365 days));
        assertEq(getLoan(id).aprBps, 1200);
        assertEq(pool.totalAssets(), 10_000e6 + lending.interestOf(id));
    }

    function test_repayFullReturnsCollateralAndPreservesReserve() public {
        uint256 id = borrow(400e6);
        vm.warp(block.timestamp + 30 days);
        uint256 debt = lending.debtOf(id);
        uint256 nav = pool.totalAssets();
        uint256 balance = usdc.balanceOf(alice);
        vm.prank(alice);
        lending.repay(id);
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(usdc.balanceOf(alice), balance - debt);
        assertEq(lending.totalDebt(), 0);
        assertEq(lending.rateWeight(), 0);
        assertEq(lending.interestNumerator(), 0);
        assertEq(pool.totalAssets(), nav);
        assertEq(pool.reserve(), 4e6);
        assertEq(lending.collateralLoan(tokenId), 0);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.repay(id);
    }

    function test_thirdPartyRepaymentReturnsCardToBorrower() public {
        uint256 id = borrow(400e6);
        vm.prank(bob);
        lending.repay(id);
        assertEq(nft.ownerOf(tokenId), alice);
    }

    function test_failedRepaymentRollsBackDebtAndCollateral() public {
        uint256 id = borrow(400e6);
        vm.prank(alice);
        usdc.approve(address(lending), 0);
        vm.expectRevert();
        vm.prank(alice);
        lending.repay(id);
        assertEq(lending.debtOf(id), 400e6);
        assertEq(nft.ownerOf(tokenId), address(lending));
    }

    function test_extendRequiresNewPricePaysInterestAndResetsTerm() public {
        uint256 id = borrow(400e6);
        vm.expectRevert(CardLending.PriceNotNewer.selector);
        vm.prank(alice);
        lending.extend(id, 10_000);
        vm.warp(block.timestamp + 10 days);
        deliverPrice(1000);
        lending.setAPR(1500);
        uint256 interest = lending.interestOf(id);
        uint256 balance = usdc.balanceOf(alice);
        uint256 nav = pool.totalAssets();
        vm.prank(alice);
        lending.extend(id, 10_000);
        CardLending.Loan memory l = getLoan(id);
        assertEq(l.maturity, block.timestamp + 30 days);
        assertEq(l.startedAt, block.timestamp);
        assertEq(l.aprBps, 1500);
        assertEq(lending.interestOf(id), 0);
        assertEq(lending.totalDebt(), 400e6);
        assertEq(usdc.balanceOf(alice), balance - interest);
        assertEq(pool.totalAssets(), nav);
        assertEq(pool.reserve(), 4e6);
    }

    function test_extendRejectsNonBorrowerExpiredLoanAndExcessiveDebt() public {
        uint256 id = borrow(400e6);
        vm.expectRevert(CardLending.NotBorrower.selector);
        vm.prank(bob);
        lending.extend(id, 10_000);
        vm.warp(block.timestamp + 1 days);
        deliverPrice(800);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.extend(id, 10_000);
        vm.warp(getLoan(id).maturity);
        vm.expectRevert(CardLending.WrongState.selector);
        vm.prank(alice);
        lending.extend(id, 10_000);
    }

    function test_extendCannotReuseSameAttestation() public {
        uint256 id = borrow(400e6);
        vm.warp(block.timestamp + 10);
        deliverPrice(1000);
        vm.prank(alice);
        lending.extend(id, 10_000);
        vm.expectRevert(CardLending.PriceNotNewer.selector);
        vm.prank(alice);
        lending.extend(id, 10_000);
    }

    function test_liquidationAtMaturityWithoutFreshOracle() public {
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity - 1);
        vm.expectRevert(CardOracle.StalePrice.selector);
        lending.liquidate(id);
        vm.warp(block.timestamp + 1);
        uint256 debt = lending.debtOf(id);
        uint256 nav = pool.totalAssets();
        vm.prank(bob);
        lending.liquidate(id);
        assertEq(lending.frozenDebt(), debt);
        assertEq(lending.activePrincipal(), 0);
        assertEq(pool.totalAssets(), nav);
        vm.warp(block.timestamp + 1 days);
        assertEq(lending.debtOf(id), debt);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.liquidate(id);
        vm.expectRevert(CardLending.WrongState.selector);
        vm.prank(alice);
        lending.extend(id, 10_000);
    }

    function test_priceLiquidationNeedsStrictlyNewerAttestationAndOver60Percent() public {
        lending.setAPR(0);
        uint256 id = borrow(300e6);
        vm.expectRevert(CardLending.PriceNotNewer.selector);
        lending.liquidate(id);
        vm.warp(block.timestamp + 1);
        deliverPrice(500); // Exactly 60%, not liquidatable.
        vm.expectRevert(CardLending.NotLiquidatable.selector);
        lending.liquidate(id);
        vm.warp(block.timestamp + 1);
        deliverPrice(499);
        lending.liquidate(id);
        assertEq(getLoan(id).auctionDebt, 300e6);
    }

    function test_zeroAnswerIsNotAPriceAndCannotLiquidateHealthyLoan() public {
        uint256 id = borrow(450e6);
        vm.warp(block.timestamp + 1);
        bytes32 request = ask();
        OracleAttestation.Attestation memory a = attestation(0);
        (bool ok, bytes memory data) = intake.deliver(request, a, sign(a));
        assertFalse(ok);
        assertEq(bytes4(data), CardOracle.BadAttestation.selector);
        assertEq(oracle.freshPrice(cardClass).price, 1000e6);
        vm.expectRevert(CardLending.PriceNotNewer.selector);
        lending.liquidate(id);
        assertEq(uint256(getLoan(id).state), uint256(CardLending.State.Active));
        assertEq(nft.ownerOf(tokenId), address(lending));
        vm.expectRevert(CardLending.WrongState.selector);
        vm.prank(bob);
        lending.buy(id, 540e6, bob);
    }

    function test_tinyPrincipalStillOwesRoundedUpInterest() public {
        uint256 id = borrow(100);
        vm.warp(block.timestamp + 30 days);
        assertEq(lending.interestOf(id), 1);
        assertEq(lending.debtOf(id), 101);
        uint256 balance = usdc.balanceOf(alice);
        vm.prank(alice);
        lending.repay(id);
        assertEq(usdc.balanceOf(alice), balance - 101);
    }

    function test_extendAtMaximumLTVSucceedsAtUnchangedPrice() public {
        uint256 id = borrow(450e6);
        vm.warp(block.timestamp + 1 days);
        deliverPrice(1000);
        uint256 interest = lending.interestOf(id);
        assertGt(interest, 0);
        vm.prank(alice);
        lending.extend(id, 1200);
        assertEq(getLoan(id).principal, 450e6);
        assertEq(lending.debtOf(id), 450e6);
        assertEq(lending.totalDebt(), 450e6);
        vm.warp(block.timestamp + 1);
        deliverPrice(999);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.extend(id, 1200);
    }

    function test_extendRefusesRateAboveBorrowerLimit() public {
        uint256 id = borrow(400e6);
        vm.warp(block.timestamp + 10 days);
        deliverPrice(1000);
        lending.setAPR(10_000);
        vm.expectRevert(CardLending.RateAboveLimit.selector);
        vm.prank(alice);
        lending.extend(id, 1200);
        assertEq(getLoan(id).aprBps, 1200);
        lending.setAPR(1200);
        vm.prank(alice);
        lending.extend(id, 1200);
        assertEq(getLoan(id).aprBps, 1200);
    }

    function test_navFollowsAuctionCurveToFloorAndWriteOff() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        // Cash 9,604 of which 4 reserved; the loan is at par while its price is at or above the debt.
        assertEq(pool.totalAssets(), 10_000e6);
        assertEq(lending.auctionMark(id), 400e6);
        vm.warp(block.timestamp + lending.PAR_WINDOW());
        assertEq(pool.totalAssets(), 10_000e6);
        vm.warp(block.timestamp + 1);
        // One second past the par window the mark dips below the debt; the reserve still covers that sliver.
        (uint256 marked, uint256 sliver) = lending.netReceivable();
        assertLt(marked, 400e6);
        assertEq(marked + sliver, 400e6);
        assertEq(pool.totalAssets(), 10_000e6);
        assertEq(lending.auctionMark(id), lending.auctionPrice(id));
        vm.warp(getLoan(id).auctionStartedAt + 12 hours);
        assertEq(lending.auctionPrice(id), 340e6);
        // Reserve of 4 USDC covers part of the 60 USDC expected shortfall, so NAV is 9,600 + 340 + 4.
        assertEq(pool.totalAssets(), 9_944e6);
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        assertEq(receivable, 340e6);
        assertEq(shortfall, 60e6);
        vm.warp(getLoan(id).auctionStartedAt + 1 days);
        assertEq(pool.totalAssets(), 9_804e6);
        assertEq(lending.auctionMark(id), 200e6);
        // Unsold at the floor, the mark is written down linearly: half way through the delay it is 100.
        vm.warp(block.timestamp + lending.WRITE_OFF_DELAY() / 2);
        assertEq(lending.auctionMark(id), 100e6);
        assertEq(lending.auctionPrice(id), 200e6);
        assertEq(pool.totalAssets(), 9_704e6);
        vm.warp(getLoan(id).auctionStartedAt + 2 days - 1);
        uint256 lastMark = lending.auctionMark(id);
        assertEq(lastMark, Math.ceilDiv(uint256(400e6), 2 * 1 days));
        assertEq(pool.totalAssets(), 9_604e6 + lastMark);
        vm.warp(block.timestamp + 1);
        assertEq(lending.auctionMark(id), 0);
        assertEq(pool.totalAssets(), 9_604e6);
        assertEq(lending.frozenDebt(), 400e6);
        // A late floor purchase settles the full debt without moving NAV: the 200 above the written-off mark
        // is held back as reserve for later shortfalls instead of becoming an instant gain.
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        assertEq(pool.totalAssets(), 9_604e6);
        assertEq(pool.reserve(), 200e6);
        assertEq(pool.coveredReserve(), 0);
        assertEq(pool.availableLiquidity(), 9_604e6);
        assertEq(lending.frozenDebt(), 0);
        assertEq(lending.decayDebt(), 0);
        assertEq(lending.decayWeight(), 0);
        assertEq(lending.parDebt(), 0);
        assertEq(lending.descentDebt(), 0);
    }

    function test_exitingLenderCannotLeaveUnsoldAuctionLossToOthers() public {
        lending.setAPR(0);
        usdc.mint(bob, 10_000e6);
        vm.prank(bob);
        pool.deposit(10_000e6, bob);
        uint256 id = borrow(450e6);
        vm.warp(block.timestamp + 1);
        deliverPrice(100);
        lending.liquidate(id);
        vm.warp(block.timestamp + 1 days);
        assertEq(lending.auctionPrice(id), 225e6);
        uint256 recoverable = pool.availableLiquidity() + 225e6 + pool.reserve();
        assertEq(pool.totalAssets(), recoverable);
        uint256 shares = pool.balanceOf(lender);
        vm.prank(lender);
        uint256 received = pool.redeem(shares, lender, lender);
        assertLe(received, recoverable / 2);
        assertApproxEqAbs(received, recoverable / 2, 1);
        vm.prank(bob);
        lending.buy(id, 225e6, bob);
        assertEq(pool.reserve(), 0);
        assertApproxEqAbs(pool.previewRedeem(pool.balanceOf(bob)), recoverable / 2, 1);
    }

    function test_auctionBookAggregatesMatchPerLoanMarksWithRemovals() public {
        lending.setAPR(0);
        uint256[3] memory ids;
        uint256[3] memory tokens;
        tokens[0] = tokenId;
        tokens[1] = nft.mint(alice, cardMetadata("100002"));
        tokens[2] = nft.mint(alice, cardMetadata("100003"));
        deliverPrice(1000);
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            ids[i] = lending.borrow(tokens[i], 300e6 + i * 50e6);
        }
        vm.warp(getLoan(ids[0]).maturity);
        lending.liquidate(ids[0]);
        vm.warp(block.timestamp + 5 hours);
        lending.liquidate(ids[1]);
        vm.warp(block.timestamp + 5 hours);
        lending.liquidate(ids[2]);
        _assertBookMatchesLoans(ids);
        vm.warp(block.timestamp + 3 hours); // first descending, second at par edge, third at par
        _assertBookMatchesLoans(ids);
        vm.prank(bob);
        lending.buy(ids[1], type(uint256).max, bob); // removal from the middle of the queue
        _assertBookMatchesLoans(ids);
        vm.warp(block.timestamp + 20 hours); // first at floor, third descending
        _assertBookMatchesLoans(ids);
        lending.syncAuctions();
        _assertBookMatchesLoans(ids);
        // The sync walked past the first (decaying past its floor) and the closed second; the third still descends.
        assertEq(lending.parHead(), 3);
        assertEq(lending.descentHead(), 2);
        assertEq(lending.decayHead(), 0);
        assertEq(lending.decayDebt(), 300e6);
        vm.prank(alice);
        lending.repay(ids[0]); // removal while decaying
        _assertBookMatchesLoans(ids);
        assertEq(lending.decayDebt(), 0);
        vm.warp(block.timestamp + 3 days); // third written off
        _assertBookMatchesLoans(ids);
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        assertEq(receivable, 0);
        assertEq(shortfall, 400e6);
        vm.prank(bob);
        lending.buy(ids[2], type(uint256).max, bob);
        _assertBookMatchesLoans(ids);
        assertEq(lending.frozenDebt(), 0);
        assertEq(lending.parDebt() + lending.descentDebt() + lending.decayDebt() + lending.decayWeight(), 0);
    }

    function _assertBookMatchesLoans(uint256[3] memory ids) internal view {
        uint256 marks;
        uint256 frozen;
        uint256 rounded;
        for (uint256 i; i < 3; ++i) {
            if (getLoan(ids[i]).state != CardLending.State.Auction) continue;
            uint256 mark = lending.auctionMark(ids[i]);
            marks += mark;
            frozen += lending.debtOf(ids[i]);
            if (mark != 0 && mark < lending.debtOf(ids[i])) ++rounded;
        }
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        assertApproxEqAbs(receivable, marks, rounded);
        assertEq(receivable + shortfall, frozen);
        assertEq(lending.frozenDebt(), frozen);
    }

    function testFuzz_auctionMarkNeverExceedsDebtOrPriceAndTracksPerLoan(uint32 gapSeed, uint32 timeSeed) public {
        lending.setAPR(0);
        uint256 otherToken = nft.mint(alice, cardMetadata("100002"));
        deliverPrice(1000);
        vm.startPrank(alice);
        uint256 first = lending.borrow(tokenId, 400e6);
        uint256 second = lending.borrow(otherToken, 250e6);
        vm.stopPrank();
        vm.warp(getLoan(first).maturity);
        lending.liquidate(first);
        vm.warp(block.timestamp + bound(uint256(gapSeed), 0, 3 days));
        lending.liquidate(second);
        vm.warp(block.timestamp + bound(uint256(timeSeed), 0, 3 days));
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        uint256 marks = lending.auctionMark(first) + lending.auctionMark(second);
        assertApproxEqAbs(receivable, marks, 2);
        assertLe(receivable, 650e6);
        assertEq(receivable + shortfall, 650e6);
        assertLe(lending.auctionMark(first), lending.auctionPrice(first));
        assertLe(lending.auctionMark(second), lending.auctionPrice(second));
        uint256 navBefore = pool.totalAssets();
        lending.syncAuctions();
        assertEq(pool.totalAssets(), navBefore);
    }

    function test_auctionExactStartMidpointEndAndBeyond() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        assertEq(lending.auctionPrice(id), 480e6);
        vm.warp(block.timestamp + 12 hours);
        assertEq(lending.auctionPrice(id), 340e6);
        vm.warp(block.timestamp + 12 hours);
        assertEq(lending.auctionPrice(id), 200e6);
        vm.warp(block.timestamp + 365 days);
        assertEq(lending.auctionPrice(id), 200e6);
    }

    function test_auctionSurplusClaimUsesPullPayment() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 poolNAV = pool.totalAssets();
        vm.prank(bob);
        lending.buy(id, 480e6, bob);
        assertEq(nft.ownerOf(tokenId), bob);
        assertEq(lending.debtOf(id), 0);
        assertEq(lending.totalDebt(), 0);
        assertEq(lending.surplus(alice), 80e6);
        assertEq(lending.totalSurplus(), 80e6);
        assertEq(usdc.balanceOf(address(lending)), 80e6);
        assertEq(pool.totalAssets(), poolNAV);
        uint256 borrowerBalance = usdc.balanceOf(alice);
        vm.prank(alice);
        lending.claimSurplus(alice);
        assertEq(usdc.balanceOf(alice), borrowerBalance + 80e6);
        assertEq(lending.totalSurplus(), 0);
        vm.expectRevert(CardLending.InvalidAmount.selector);
        vm.prank(alice);
        lending.claimSurplus(alice);
        vm.expectRevert(CardLending.WrongState.selector);
        vm.prank(bob);
        lending.buy(id, 480e6, bob);
    }

    function test_auctionShortfallUsesReserveThenRecognizesLenderLoss() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 nav = pool.totalAssets();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        assertEq(pool.reserve(), 0);
        assertEq(pool.totalAssets(), nav - 196e6);
        assertEq(lending.totalDebt(), 0);
        assertEq(lending.surplus(alice), 0);
        assertEq(nft.ownerOf(tokenId), bob);
    }

    function test_fundedReserveAbsorbsEntireShortfall() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.prank(bob);
        pool.fundReserve(300e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 nav = pool.totalAssets();
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        assertEq(pool.reserve(), 104e6);
        assertEq(pool.totalAssets(), nav);
    }

    /// Reviewer finding 965d7546, case A: a floor purchase of a written-off loan is NAV-neutral, so a same-block
    /// deposit/redeem around it takes none of the pool's recovery.
    function test_settlingWrittenOffAuctionCannotBeSandwichedForPoolRecovery() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(block.timestamp + 2 days);
        assertEq(lending.auctionMark(id), 0);
        assertEq(lending.auctionPrice(id), 200e6);
        assertEq(pool.totalAssets(), 9_604e6);
        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 lenderClaim = pool.previewRedeem(pool.balanceOf(lender));
        vm.startPrank(bob);
        uint256 shares = pool.deposit(10_000e6, bob);
        lending.buy(id, 200e6, bob);
        pool.redeem(shares, bob, bob);
        vm.stopPrank();
        uint256 cost = bobBefore - usdc.balanceOf(bob);
        assertGe(cost, 200e6);
        assertLe(cost, 200e6 + 1);
        assertGe(pool.previewRedeem(pool.balanceOf(lender)), lenderClaim);
        assertApproxEqAbs(pool.totalAssets(), 9_604e6, 1);
        assertEq(pool.reserve(), 200e6);
        assertEq(pool.coveredReserve(), 0);
        assertEq(nft.ownerOf(tokenId), bob);
    }

    /// Reviewer finding 965d7546, case B: repaying an auctioned loan in full is NAV-neutral too; the borrower pays the
    /// whole frozen debt and the part above the mark becomes reserve.
    function test_repayingAuctionedLoanCannotBeSandwichedForPoolRecovery() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(block.timestamp + 2 days);
        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 lenderClaim = pool.previewRedeem(pool.balanceOf(lender));
        vm.startPrank(alice);
        uint256 shares = pool.deposit(1_000_000e6, alice);
        lending.repay(id);
        pool.redeem(shares, alice, alice);
        vm.stopPrank();
        uint256 cost = aliceBefore - usdc.balanceOf(alice);
        assertGe(cost, 400e6);
        assertLe(cost, 400e6 + 1);
        assertEq(nft.ownerOf(tokenId), alice);
        assertGe(pool.previewRedeem(pool.balanceOf(lender)), lenderClaim);
        assertApproxEqAbs(pool.totalAssets(), 9_604e6, 1);
        assertEq(pool.reserve(), 400e6);
        assertEq(pool.coveredReserve(), 0);
    }

    function test_repayDuringDescentHoldsBackRecoveryAsReserve() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(block.timestamp + 12 hours);
        assertEq(pool.totalAssets(), 9_944e6); // 9,600 cash + 340 mark + the 4 reserve covering part of the 60
        vm.prank(alice);
        lending.repay(id);
        assertEq(pool.totalAssets(), 9_944e6);
        assertEq(pool.reserve(), 60e6);
        assertEq(pool.coveredReserve(), 0);
        assertEq(pool.availableLiquidity(), 9_944e6);
        assertEq(lending.totalDebt(), 0);
    }

    function test_heldBackRecoveryCoversLaterShortfallsOnly() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        assertEq(pool.totalAssets(), 9_604e6);
        assertEq(pool.reserve(), 200e6);
        assertEq(pool.coveredReserve(), 0);
        // A second loan's auction descends to its floor; the held-back 200 absorbs that whole shortfall, so lender
        // NAV never moves, and the floor sale then spends exactly the counted reserve.
        uint256 other = nft.mint(alice, cardMetadata("100002"));
        deliverPrice(1000);
        vm.prank(alice);
        uint256 second = lending.borrow(other, 400e6);
        assertEq(pool.totalAssets(), 9_604e6);
        assertEq(pool.reserve(), 204e6);
        vm.warp(getLoan(second).maturity);
        lending.liquidate(second);
        assertEq(pool.totalAssets(), 9_604e6);
        vm.warp(block.timestamp + 12 hours);
        assertEq(pool.coveredReserve(), 60e6);
        assertEq(pool.totalAssets(), 9_604e6);
        vm.warp(block.timestamp + 12 hours);
        assertEq(pool.coveredReserve(), 200e6);
        assertEq(pool.totalAssets(), 9_604e6);
        vm.prank(bob);
        lending.buy(second, 200e6, bob);
        assertEq(pool.totalAssets(), 9_604e6);
        assertEq(pool.reserve(), 4e6);
        assertEq(pool.coveredReserve(), 0);
        assertEq(pool.availableLiquidity(), 9_604e6);
    }

    function test_reserveDonationAfterLossMovesNoNAVAndCoversLaterShortfallsOnly() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(block.timestamp + 1 days);
        assertEq(pool.totalAssets(), 9_804e6);
        vm.prank(bob);
        pool.fundReserve(1_000e6);
        assertEq(pool.totalAssets(), 9_804e6);
        assertEq(pool.coveredReserve(), 4e6);
        // The floor sale spends only the 4 that NAV counted; the donation is kept for later mark-downs.
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        assertEq(pool.totalAssets(), 9_804e6);
        assertEq(pool.reserve(), 1_000e6);
        assertEq(pool.coveredReserve(), 0);
    }

    function test_navIsContinuousThroughFloorAndWriteOff() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 start = block.timestamp;
        uint256 previous = pool.totalAssets();
        assertEq(previous, 10_000e6);
        for (uint256 step = 1; step <= 50; ++step) {
            vm.warp(start + step * 1 hours);
            uint256 current = pool.totalAssets();
            assertLe(current, previous);
            // The steepest hourly fall is on the Dutch curve itself: 70% of 400 over 24 hours is under 12 per hour.
            assertLe(previous - current, 12e6);
            previous = current;
        }
        assertEq(pool.totalAssets(), 9_604e6);
        assertEq(lending.auctionMark(id), 0);
    }

    function test_repayDuringAuctionStopsSale() public {
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.prank(alice);
        lending.repay(id);
        assertEq(lending.frozenDebt(), 0);
        assertEq(nft.ownerOf(tokenId), alice);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.auctionPrice(id);
    }

    function test_slippageAndRejectingReceiverRollBackSale() public {
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 price = lending.auctionPrice(id);
        vm.expectRevert(CardLending.Slippage.selector);
        vm.prank(bob);
        lending.buy(id, price - 1, bob);
        AuctionReceiver receiver = new AuctionReceiver(lending, id, true);
        uint256 balance = usdc.balanceOf(bob);
        vm.expectRevert("reject card");
        vm.prank(bob);
        lending.buy(id, price, address(receiver));
        assertEq(usdc.balanceOf(bob), balance);
        assertEq(nft.ownerOf(tokenId), address(lending));
        assertEq(uint256(getLoan(id).state), uint256(CardLending.State.Auction));
    }

    function test_NFTReceiverCannotReenterAuction() public {
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        AuctionReceiver receiver = new AuctionReceiver(lending, id, false);
        uint256 price = lending.auctionPrice(id);
        vm.prank(bob);
        lending.buy(id, price, address(receiver));
        assertTrue(receiver.reentryBlocked());
        assertEq(nft.ownerOf(tokenId), address(receiver));
    }

    function test_pauseStopsRiskButRepaymentAndAuctionSettlementRemainLive() public {
        uint256 id = borrow(400e6);
        lending.setGuardian(guardian);
        vm.prank(guardian);
        lending.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        lending.extend(id, 10_000);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lending.liquidate(id);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 400e6);
        vm.prank(alice);
        lending.repay(id);
        lending.unpause();
        vm.warp(block.timestamp + 1);
        id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        lending.pause();
        pool.pause();
        vm.prank(bob);
        lending.buy(id, 1000e6, bob);
        vm.prank(alice);
        lending.claimSurplus(alice);
    }

    function test_multipleLoanAccrualRemovalAndExtensionConserveAssets() public {
        uint256 a = borrow(400e6);
        vm.warp(block.timestamp + 3 days);
        uint256 otherToken = nft.mint(alice, cardMetadata("100002"));
        deliverPrice(1000);
        lending.setAPR(2500);
        vm.prank(alice);
        uint256 b = lending.borrow(otherToken, 300e6);
        vm.warp(block.timestamp + 7 days);
        uint256 sum = lending.debtOf(a) + lending.debtOf(b);
        assertApproxEqAbs(lending.totalDebt(), sum, 1);
        deliverPrice(1000);
        vm.prank(alice);
        lending.extend(a, 10_000);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        lending.repay(b);
        assertEq(lending.totalDebt(), lending.debtOf(a));
        vm.prank(alice);
        lending.repay(a);
        assertEq(lending.totalDebt(), 0);
        assertEq(lending.interestNumerator(), 0);
        assertEq(lending.rateWeight(), 0);
        assertEq(pool.availableLiquidity() + pool.reserve(), usdc.balanceOf(address(pool)));
    }

    function test_APRBoundsAndOwnerOnly() public {
        vm.expectRevert(CardLending.InvalidRate.selector);
        lending.setAPR(10001);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        lending.setAPR(1000);
        lending.setAPR(0);
        assertEq(lending.aprBps(), 0);
        lending.setAPR(10000);
        assertEq(lending.aprBps(), 10000);
    }

    function testFuzz_linearInterestAndRepaymentConservation(uint96 amountSeed, uint32 elapsedSeed, uint16 rateSeed)
        public
    {
        uint256 amount = bound(uint256(amountSeed), 100, 450e6);
        uint256 elapsed = bound(uint256(elapsedSeed), 0, 3650 days);
        uint16 rate = uint16(bound(uint256(rateSeed), 0, 10000));
        lending.setAPR(rate);
        uint256 id = borrow(amount);
        vm.warp(block.timestamp + elapsed);
        uint256 interest = Math.ceilDiv(amount * rate * elapsed, 10000 * 365 days);
        assertEq(lending.interestOf(id), interest);
        assertGe(interest * 10000 * 365 days, amount * rate * elapsed);
        uint256 nav = pool.totalAssets();
        vm.prank(alice);
        lending.repay(id);
        assertEq(pool.totalAssets(), nav);
        assertEq(lending.totalDebt(), 0);
    }

    function testFuzz_auctionMonotonicAndBounded(uint32 timeSeed, uint32 deltaSeed) public {
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 debt = lending.debtOf(id);
        uint256 t = bound(uint256(timeSeed), 0, 2 days);
        uint256 delta = bound(uint256(deltaSeed), 0, 2 days);
        vm.warp(block.timestamp + t);
        uint256 first = lending.auctionPrice(id);
        vm.warp(block.timestamp + delta);
        uint256 second = lending.auctionPrice(id);
        assertLe(second, first);
        assertGe(second, Math.ceilDiv(debt, 2));
        assertLe(first, Math.mulDiv(debt, 120, 100, Math.Rounding.Ceil));
    }
}
