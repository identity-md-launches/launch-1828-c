// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardPool} from "../src/CardPool.sol";
import {CardLending} from "../src/CardLending.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CardPoolTest is Fixture {
    function test_depositMintWithdrawRedeemAndDecimals() public {
        assertEq(pool.decimals(), 12);
        assertEq(pool.asset(), address(usdc));
        assertEq(pool.balanceOf(lender), 10_000e12);
        vm.startPrank(bob);
        uint256 shares = pool.deposit(100e6, bob);
        assertEq(shares, 100e12);
        assertEq(pool.mint(50e12, bob), 50e6);
        assertEq(pool.withdraw(75e6, bob, bob), 75e12);
        assertEq(pool.redeem(75e12, bob, bob), 75e6);
        vm.stopPrank();
        assertEq(pool.balanceOf(bob), 0);
        assertEq(pool.totalAssets(), 10000e6);
    }

    function test_withdrawByApprovedShareSpender() public {
        vm.prank(lender);
        pool.approve(bob, 100e12);
        uint256 beforeBalance = usdc.balanceOf(bob);
        vm.prank(bob);
        pool.withdraw(100e6, bob, lender);
        assertEq(usdc.balanceOf(bob), beforeBalance + 100e6);
        assertEq(pool.allowance(lender, bob), 0);
        vm.expectRevert();
        vm.prank(bob);
        pool.withdraw(1e6, bob, lender);
    }

    function test_utilizationLimitsWithdrawalAndRedemption() public {
        borrow(450e6);
        assertEq(pool.maxWithdraw(lender), 9550e6);
        assertEq(pool.maxRedeem(lender), 9550e12);
        vm.expectRevert();
        vm.prank(lender);
        pool.withdraw(9550e6 + 1, lender, lender);
        vm.expectRevert();
        vm.prank(lender);
        pool.redeem(9550e12 + 1e6, lender, lender);
        vm.prank(lender);
        pool.withdraw(9550e6, lender, lender);
        assertEq(pool.availableLiquidity(), 0);
        assertEq(usdc.balanceOf(address(pool)), pool.reserve());
        assertEq(pool.maxWithdraw(lender), 0);
        vm.prank(alice);
        lending.repay(1);
        assertEq(pool.maxWithdraw(lender), 450e6);
        uint256 remainingShares = pool.balanceOf(lender);
        vm.prank(lender);
        pool.redeem(remainingShares, lender, lender);
        assertEq(pool.totalSupply(), 0);
        assertEq(pool.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(pool)), 4_500_000);
    }

    function test_accruedInterestPreventsLateDepositorCapturingPastYield() public {
        uint256 id = borrow(400e6);
        vm.warp(block.timestamp + 30 days);
        uint256 debt = lending.debtOf(id);
        uint256 bobBalance = usdc.balanceOf(bob);
        vm.startPrank(bob);
        uint256 shares = pool.deposit(1000e6, bob);
        vm.stopPrank();
        assertLt(shares, 1000e12);
        vm.prank(alice);
        lending.repay(id);
        vm.prank(bob);
        uint256 returned = pool.redeem(shares, bob, bob);
        assertLe(returned, 1000e6);
        assertApproxEqAbs(returned, 1000e6, 1);
        assertApproxEqAbs(usdc.balanceOf(bob), bobBalance, 1);
        assertApproxEqAbs(pool.totalAssets(), 10_000e6 + debt - 400e6, 1);
    }

    function test_reserveFundingNeverMintsSharesOrInflatesNAV() public {
        uint256 nav = pool.totalAssets();
        uint256 supply = pool.totalSupply();
        vm.prank(bob);
        pool.fundReserve(100e6);
        assertEq(pool.reserve(), 100e6);
        assertEq(pool.totalAssets(), nav);
        assertEq(pool.totalSupply(), supply);
        assertEq(pool.availableLiquidity(), 10000e6);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        pool.fundReserve(0);
    }

    function test_onlyConfiguredLendingCanDrawOrSettleAndCannotBeReplaced() public {
        vm.expectRevert(CardPool.NotLending.selector);
        pool.draw(bob, 100e6, 1e6);
        vm.expectRevert(CardPool.NotLending.selector);
        pool.settle(0, 100e6);
        vm.expectRevert(CardPool.LendingAlreadyConfigured.selector);
        pool.setLending(bob);
        CardPool unconfigured = new CardPool(address(this), usdc);
        vm.expectRevert(CardPool.LendingNotConfigured.selector);
        unconfigured.draw(bob, 100e6, 1e6);
        vm.expectRevert();
        unconfigured.setLending(bob);
        vm.expectRevert(); // It points at another pool.
        unconfigured.setLending(address(lending));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        unconfigured.setLending(address(lending));
    }

    function test_pauseBlocksDepositsAndNewDrawsButAllowsExitAndRepay() public {
        uint256 id = borrow(400e6);
        pool.pause();
        assertEq(pool.maxDeposit(bob), 0);
        assertEq(pool.maxMint(bob), 0);
        vm.expectRevert();
        vm.prank(bob);
        pool.deposit(1e6, bob);
        vm.expectRevert();
        vm.prank(bob);
        pool.mint(1e12, bob);
        vm.prank(lender);
        pool.withdraw(1e6, lender, lender);
        vm.prank(alice);
        lending.repay(id);
        pool.unpause();
        vm.prank(bob);
        pool.deposit(1e6, bob);
    }

    function test_roundingDirectionsAfterDonation() public {
        usdc.transfer(address(pool), 1234567);
        uint256 assets = 987654321;
        uint256 shares = 1234567890123;
        uint256 numerator = pool.totalSupply() + 1e6;
        uint256 denominator = pool.totalAssets() + 1;
        assertEq(pool.convertToShares(assets), Math.mulDiv(assets, numerator, denominator));
        assertEq(pool.previewDeposit(assets), Math.mulDiv(assets, numerator, denominator));
        assertEq(pool.previewWithdraw(assets), Math.mulDiv(assets, numerator, denominator, Math.Rounding.Ceil));
        assertEq(pool.convertToAssets(shares), Math.mulDiv(shares, denominator, numerator));
        assertEq(pool.previewRedeem(shares), Math.mulDiv(shares, denominator, numerator));
        assertEq(pool.previewMint(shares), Math.mulDiv(shares, denominator, numerator, Math.Rounding.Ceil));
    }

    function test_virtualSharesPreventProfitableFirstDepositorInflation() public {
        CardPool emptyPool = new CardPool(address(this), usdc);
        usdc.approve(address(emptyPool), type(uint256).max);
        uint256 beforeBalance = usdc.balanceOf(address(this));
        emptyPool.deposit(1, address(this));
        usdc.transfer(address(emptyPool), 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(emptyPool), 2000e6);
        uint256 victimShares = emptyPool.deposit(2000e6, bob);
        assertGt(victimShares, 0);
        vm.stopPrank();
        emptyPool.redeem(emptyPool.balanceOf(address(this)), address(this), address(this));
        assertLt(usdc.balanceOf(address(this)), beforeBalance);
        assertGe(emptyPool.previewRedeem(victimShares), 2000e6 - 2000);
    }

    function test_zeroAndDustActionsRejected() public {
        vm.expectRevert(CardPool.InvalidAmount.selector);
        pool.deposit(0, bob);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        pool.mint(0, bob);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        pool.withdraw(0, bob, bob);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        pool.redeem(0, bob, bob);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        vm.prank(lender);
        pool.redeem(1, lender, lender);
    }

    function testFuzz_depositRedeemCannotCreateAssets(uint96 amountSeed, uint96 donationSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 10000e6);
        uint256 donation = bound(uint256(donationSeed), 0, 10000e6);
        usdc.transfer(address(pool), donation);
        uint256 beforeBalance = usdc.balanceOf(bob);
        vm.startPrank(bob);
        uint256 shares = pool.deposit(amount, bob);
        uint256 preview = pool.previewRedeem(shares);
        if (preview != 0) pool.redeem(shares, bob, bob);
        vm.stopPrank();
        assertLe(usdc.balanceOf(bob), beforeBalance);
        assertLe(preview, amount);
        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)));
    }
}
