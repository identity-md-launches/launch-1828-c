// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardLending} from "../src/CardLending.sol";
import {CardOracle} from "../src/CardOracle.sol";
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
        assertEq(lending.interestOf(id), uint256(400e6) * 1200 * 15 days / (10_000 * 365 days));
        vm.warp(block.timestamp + 30 days);
        assertEq(lending.interestOf(id), uint256(400e6) * 1200 * 45 days / (10_000 * 365 days));
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
        lending.extend(id);
        vm.warp(block.timestamp + 10 days);
        deliverPrice(1000);
        lending.setAPR(1500);
        uint256 interest = lending.interestOf(id);
        uint256 balance = usdc.balanceOf(alice);
        uint256 nav = pool.totalAssets();
        vm.prank(alice);
        lending.extend(id);
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
        lending.extend(id);
        vm.warp(block.timestamp + 1 days);
        deliverPrice(800);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.extend(id);
        vm.warp(getLoan(id).maturity);
        vm.expectRevert(CardLending.WrongState.selector);
        vm.prank(alice);
        lending.extend(id);
    }

    function test_extendCannotReuseSameAttestation() public {
        uint256 id = borrow(400e6);
        vm.warp(block.timestamp + 10);
        deliverPrice(1000);
        vm.prank(alice);
        lending.extend(id);
        vm.expectRevert(CardLending.PriceNotNewer.selector);
        vm.prank(alice);
        lending.extend(id);
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
        lending.extend(id);
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

    function test_zeroNewPriceAllowsLiquidation() public {
        uint256 id = borrow(300e6);
        vm.warp(block.timestamp + 1);
        deliverPrice(0);
        lending.liquidate(id);
        assertEq(uint256(getLoan(id).state), uint256(CardLending.State.Auction));
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
        lending.extend(id);
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
        lending.extend(a);
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
        uint256 interest = amount * rate * elapsed / (10000 * 365 days);
        assertEq(lending.interestOf(id), interest);
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
