// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardLending} from "src/CardLending.sol";
import {CardPool} from "src/CardPool.sol";

/// @dev Edges of the revised settlement: the pool's counted-reserve checkpoint, the hold-back of recoveries above
/// the mark, the release of cover that no longer backs a shortfall, and sandwiches in every auction phase.
contract CardSettlementEdgesTest is Fixture {
    uint256 internal constant PAR_WINDOW = 24_685;

    struct Snap {
        uint256 nav;
        uint256 cash;
        uint256 reserve;
        uint256 covered;
        uint256 receivable;
        uint256 lenderClaim;
    }

    function _snap() internal view returns (Snap memory s) {
        s.nav = pool.totalAssets();
        s.cash = usdc.balanceOf(address(pool));
        s.reserve = pool.reserve();
        s.covered = pool.coveredReserve();
        (s.receivable,) = lending.netReceivable();
        s.lenderClaim = pool.previewRedeem(pool.balanceOf(lender));
    }

    function _assertNeutral(Snap memory s, uint256 payment, string memory label) internal view {
        assertEq(pool.totalAssets(), s.nav, string.concat("NAV ", label));
        assertEq(usdc.balanceOf(address(pool)), s.cash + payment, string.concat("cash ", label));
        assertEq(pool.previewRedeem(pool.balanceOf(lender)), s.lenderClaim, string.concat("lender claim ", label));
        assertEq(pool.totalAssets(), pool.availableLiquidity() + _receivable() + pool.coveredReserve(), label);
    }

    function _receivable() internal view returns (uint256 r) {
        (r,) = lending.netReceivable();
    }

    function _secondLoan(uint256 amount) internal returns (uint256 id) {
        uint256 other = nft.mint(alice, cardMetadata("second card"));
        vm.warp(vm.getBlockTimestamp() + 1); // the oracle only stores a strictly newer quote
        deliverPrice(1000);
        vm.prank(alice);
        id = lending.borrow(other, amount);
    }

    function test_purchaseAtParPaysDebtSurplusAndTouchesNoReserve() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        assertEq(lending.auctionPrice(id), 480e6);
        Snap memory s = _snap();
        assertEq(s.covered, 0);
        vm.prank(bob);
        lending.buy(id, 480e6, bob);
        _assertNeutral(s, 400e6, "par purchase");
        assertEq(pool.reserve(), 4e6, "no reserve spent or held back when the mark is the debt");
        assertEq(lending.surplus(alice), 80e6);
    }

    function test_purchaseMidDescentSpendsExactlyTheCountedCover() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        Snap memory s = _snap();
        assertEq(s.covered, 4e6, "the fee covers 4 of the expected 60 loss");
        assertEq(s.nav, 9_944e6);
        vm.prank(bob);
        lending.buy(id, 340e6, bob);
        _assertNeutral(s, 340e6, "descent purchase");
        assertEq(pool.reserve(), 0, "the whole counted cover is spent on the 60 shortfall");
        assertEq(pool.coveredReserve(), 0);
        assertEq(pool.availableLiquidity(), 9_944e6);
    }

    function test_purchaseDuringWriteDownHoldsBackTheFloorAboveTheMark() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(vm.getBlockTimestamp() + 36 hours);
        assertEq(lending.auctionMark(id), 100e6);
        assertEq(lending.auctionPrice(id), 200e6);
        Snap memory s = _snap();
        assertEq(s.nav, 9_704e6);
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        _assertNeutral(s, 200e6, "write-down purchase");
        // The counted 4 is spent against the 200 shortfall; the 100 collected above the mark is held back.
        assertEq(pool.reserve(), 100e6);
        assertEq(pool.coveredReserve(), 0);
        assertEq(pool.availableLiquidity(), 9_704e6);
    }

    function test_coverLeftWithoutAShortfallIsReleasedRatherThanHeldBack() public {
        lending.setAPR(0);
        vm.prank(bob);
        pool.fundReserve(1_000e6);
        uint256 first = borrow(400e6);
        uint256 second = _secondLoan(400e6);
        vm.warp(getLoan(second).maturity);
        lending.liquidate(first);
        lending.liquidate(second);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(pool.reserve(), 1_008e6);
        assertEq(pool.coveredReserve(), 800e6, "the donation made before the losses covers them in full");
        assertEq(pool.totalAssets(), 10_000e6, "lenders carried no loss");
        Snap memory s = _snap();
        vm.prank(bob);
        lending.buy(first, 200e6, bob);
        _assertNeutral(s, 200e6, "floor purchase with excess cover");
        // 200 of counted cover is spent on the first loan, 400 keeps backing the second, and the remaining 200 of
        // cover is released: nothing is held back because the 200 collected is exactly that release.
        assertEq(pool.reserve(), 808e6);
        assertEq(pool.coveredReserve(), 400e6);
        s = _snap();
        vm.prank(alice);
        lending.repay(second);
        _assertNeutral(s, 400e6, "full repayment with excess cover");
        assertEq(pool.reserve(), 808e6, "the full repayment releases the 400 cover instead of holding it back");
        assertEq(pool.coveredReserve(), 0);
        assertEq(pool.totalAssets(), 10_000e6);
        assertEq(pool.availableLiquidity(), 10_000e6);
    }

    function test_feeReservedAfterALossCoversOnlyLaterMarkDowns() public {
        lending.setAPR(0);
        uint256 first = borrow(400e6);
        vm.warp(getLoan(first).maturity);
        lending.liquidate(first);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(pool.coveredReserve(), 4e6);
        assertEq(pool.totalAssets(), 9_604e6);
        uint256 second = _secondLoan(400e6);
        assertEq(pool.reserve(), 8e6);
        assertEq(pool.coveredReserve(), 4e6, "the new fee does not re-rate the first loss");
        assertEq(pool.totalAssets(), 9_604e6);
        vm.warp(getLoan(second).maturity);
        lending.liquidate(second);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(pool.coveredReserve(), 8e6, "the new fee covers the second loan's mark-down");
        assertEq(pool.totalAssets(), 9_604e6 - 60e6 + 4e6);
    }

    function test_oneUnitReserveDonationCannotReRateButGrowsWithLaterMarkDowns() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        uint256 nav = pool.totalAssets();
        vm.prank(bob);
        pool.fundReserve(1);
        assertEq(pool.coveredReserve(), 4e6);
        assertEq(pool.totalAssets(), nav);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        assertEq(pool.coveredReserve(), 4e6 + 1, "the donated unit covers the next mark-down");
        assertEq(pool.totalAssets(), nav - 140e6 + 1);
    }

    function test_extensionHoldsBackTheRoundingUnitTheAggregateNeverCarried() public {
        lending.setAPR(1);
        uint256 first = borrow(2);
        uint256 otherToken = nft.mint(alice, cardMetadata("tiny second loan"));
        vm.prank(alice);
        lending.borrow(otherToken, 2);
        vm.warp(vm.getBlockTimestamp() + 1);
        deliverPrice(1000);
        assertEq(lending.interestOf(first), 1);
        assertEq(lending.totalDebt(), 5, "two loans owing one unit each are carried as one");
        Snap memory s = _snap();
        vm.prank(alice);
        lending.extend(first, 1);
        _assertNeutral(s, 1, "extension");
        assertEq(pool.reserve(), 3, "the unit paid above the aggregate is reserve, not a second fee");
        assertEq(lending.totalDebt(), 5, "the remaining loan still rounds up to one unit");
    }

    function test_repaymentOfADecayingLoanHoldsBackDebtAboveMarkLessSpentCover() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(vm.getBlockTimestamp() + 36 hours);
        Snap memory s = _snap();
        assertEq(s.covered, 4e6);
        vm.prank(alice);
        lending.repay(id);
        _assertNeutral(s, 400e6, "decaying repayment");
        // Nothing is spent (no shortfall survives a full repayment); the 4 cover is released and the remaining
        // 296 above the 100 mark is held back.
        assertEq(pool.reserve(), 4e6 + 296e6);
        assertEq(pool.coveredReserve(), 0);
        assertEq(nft.ownerOf(tokenId), alice);
    }

    function test_openingAnAuctionMovesNavByAtMostOneRoundingUnit() public {
        lending.setAPR(1);
        uint256 first = borrow(2);
        uint256 otherToken = nft.mint(alice, cardMetadata("tiny second loan"));
        vm.prank(alice);
        uint256 second = lending.borrow(otherToken, 2);
        vm.warp(getLoan(second).maturity);
        uint256 nav = pool.totalAssets();
        lending.liquidate(first);
        assertGe(pool.totalAssets(), nav);
        assertLe(pool.totalAssets(), nav + 1);
        nav = pool.totalAssets();
        lending.liquidate(second);
        assertGe(pool.totalAssets(), nav);
        assertLe(pool.totalAssets(), nav + 1);
        assertEq(lending.frozenDebt(), lending.debtOf(first) + lending.debtOf(second));
    }

    function test_heldBackReserveIsNeverLenderCashAndHasNoRelease() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(bob);
        lending.buy(id, 200e6, bob);
        assertEq(pool.reserve(), 200e6);
        assertEq(usdc.balanceOf(address(pool)), 9_804e6);
        assertEq(pool.availableLiquidity(), 9_604e6);
        assertApproxEqAbs(
            pool.maxWithdraw(lender), 9_604e6, 1, "the recovery is not withdrawable by the lenders who bore the loss"
        );
        uint256 exit = pool.maxRedeem(lender);
        vm.prank(lender);
        pool.redeem(exit, lender, lender);
        assertLe(pool.previewRedeem(pool.balanceOf(lender)), 1, "only dust shares remain");
        assertApproxEqAbs(
            usdc.balanceOf(address(pool)), 200e6, 1, "the recovery stays behind with no owner function to move it"
        );
        assertLe(pool.totalAssets(), 1);
        // A later lender's first deposit is priced on an empty NAV, so the 200 does not accrue to them either.
        vm.prank(bob);
        uint256 shares = pool.deposit(1_000e6, bob);
        assertLe(pool.previewRedeem(shares), 1_000e6);
        assertGe(pool.previewRedeem(shares), 1_000e6 - 1e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_settlementIsNavNeutralInEveryPhase(uint32 elapsedSeed, uint8 modeSeed, uint96 fundSeed) public {
        uint256 elapsed = bound(elapsedSeed, 0, 3 days);
        uint256 mode = bound(modeSeed, 0, 3);
        uint256 fund = bound(fundSeed, 0, 1_000e6);
        uint256 id = borrow(400e6);
        if (fund != 0 && mode % 2 == 0) {
            vm.prank(bob);
            pool.fundReserve(fund);
        }
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        if (fund != 0 && mode % 2 == 1) {
            vm.prank(bob);
            pool.fundReserve(fund);
        }
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 debt = lending.debtOf(id);
        uint256 price = lending.auctionPrice(id);
        uint256 payment = mode < 2 ? (price < debt ? price : debt) : debt;
        Snap memory s = _snap();
        uint256 bobBefore = usdc.balanceOf(bob);
        if (mode == 0) {
            vm.prank(bob);
            lending.buy(id, price, bob);
        } else if (mode == 1) {
            // The reviewer's sandwich: deposit, settle, redeem in one block, by the buyer.
            vm.startPrank(bob);
            uint256 shares = pool.deposit(10_000e6, bob);
            lending.buy(id, price, bob);
            pool.redeem(shares, bob, bob);
            vm.stopPrank();
            assertGe(bobBefore - usdc.balanceOf(bob), price, "sandwich cannot recover part of the price");
        } else if (mode == 2) {
            vm.prank(bob);
            lending.repay(id);
        } else {
            vm.startPrank(bob);
            uint256 shares = pool.deposit(10_000e6, bob);
            lending.repay(id);
            pool.redeem(shares, bob, bob);
            vm.stopPrank();
            assertGe(bobBefore - usdc.balanceOf(bob), debt, "sandwich cannot recover part of the debt");
        }
        assertApproxEqAbs(pool.totalAssets(), s.nav, 1, "settlement is NAV neutral up to the sandwich rounding");
        assertGe(pool.previewRedeem(pool.balanceOf(lender)), s.lenderClaim, "the lender's claim never falls");
        assertLe(pool.previewRedeem(pool.balanceOf(lender)), s.lenderClaim + 1, "the lender's claim never jumps");
        uint256 maxSpent = s.covered < debt - payment ? s.covered : debt - payment;
        assertGe(pool.reserve() + maxSpent, s.reserve, "reserve spends at most the counted cover");
        assertLe(pool.reserve(), s.reserve + payment - (s.receivable - _receivable()), "held back at most the excess");
        assertEq(pool.coveredReserve(), 0, "nothing left to cover once the only auction is closed");
        assertEq(lending.frozenDebt(), 0);
        assertEq(pool.totalAssets(), pool.availableLiquidity());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_navNeverRisesAndCoverNeverFallsWithTimeAlone(uint32 firstSeed, uint32 secondSeed, uint96 fundSeed)
        public
    {
        uint256 first = bound(firstSeed, 0, 3 days);
        uint256 second = bound(secondSeed, first, 3 days);
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        uint256 fund = bound(fundSeed, 0, 500e6);
        if (fund != 0) {
            vm.prank(bob);
            pool.fundReserve(fund);
        }
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + first);
        uint256 navFirst = pool.totalAssets();
        uint256 coverFirst = pool.coveredReserve();
        uint256 markFirst = lending.auctionMark(id);
        vm.warp(start + second);
        uint256 navSecond = pool.totalAssets();
        assertLe(navSecond, navFirst, "time cannot lift NAV during an auction");
        assertLe(navFirst - navSecond, markFirst - lending.auctionMark(id), "NAV falls at most by the mark-down");
        assertGe(pool.coveredReserve(), coverFirst, "counted cover grows with the shortfall");
        assertLe(pool.coveredReserve(), pool.reserve());
        (, uint256 shortfall) = lending.netReceivable();
        assertLe(pool.coveredReserve(), shortfall);
        if (fund + 4e6 >= 400e6) assertEq(navSecond, 10_000e6, "a fully funded reserve absorbs the whole curve");
    }

    function test_directSettleIsRefusedFromAnyoneButLending() public {
        vm.expectRevert(CardPool.NotLending.selector);
        vm.prank(bob);
        pool.settle(0, 0, 0, 0);
        vm.expectRevert(CardPool.NotLending.selector);
        pool.settle(1, 1, 1, 1);
        assertEq(pool.coveredCheckpoint(), 0);
        assertEq(pool.shortfallCheckpoint(), 0);
    }
}
