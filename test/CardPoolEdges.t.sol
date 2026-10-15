// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardPool} from "src/CardPool.sol";
import {USDC4626} from "src/base/USDC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract CardPoolEdgesTest is Fixture {
    function test_directDebtHooksRejectInvalidAmountsWithoutChangingCashOrReserve() public {
        uint256 cash = usdc.balanceOf(address(pool));
        vm.expectRevert(CardPool.InvalidAmount.selector);
        vm.prank(address(lending));
        pool.draw(alice, 0, 0);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        vm.prank(address(lending));
        pool.draw(alice, 100, 100);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        vm.prank(address(lending));
        pool.draw(alice, 100, 101);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        vm.prank(address(lending));
        pool.settle(2, 1);
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(pool.reserve(), 0);
    }

    function test_failedReserveFundingCannotCreateUnbackedReserve() public {
        vm.prank(bob);
        usdc.approve(address(pool), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1e6));
        vm.prank(bob);
        pool.fundReserve(1e6);
        assertEq(pool.reserve(), 0);
        assertEq(usdc.balanceOf(address(pool)), 10_000e6);
        assertEq(pool.totalAssets(), 10_000e6);
    }

    function test_failedDepositAndMintDoNotMintUnbackedShares() public {
        vm.prank(bob);
        usdc.approve(address(pool), 0);
        uint256 supply = pool.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1e6));
        vm.prank(bob);
        pool.deposit(1e6, bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1e6));
        vm.prank(bob);
        pool.mint(1e12, bob);
        assertEq(pool.totalSupply(), supply);
        assertEq(pool.balanceOf(bob), 0);
        assertEq(pool.totalAssets(), 10_000e6);
    }

    function test_zeroShareDepositAfterLargeDonationRevertsWithoutTakingAssets() public {
        usdc.mint(address(this), 1e24);
        usdc.transfer(address(pool), 1e24);
        assertEq(pool.previewDeposit(1), 0);
        uint256 balance = usdc.balanceOf(bob);
        vm.expectRevert(CardPool.InvalidAmount.selector);
        vm.prank(bob);
        pool.deposit(1, bob);
        assertEq(usdc.balanceOf(bob), balance);
        assertEq(pool.balanceOf(bob), 0);
    }

    function test_delegatedRedeemUsesShareAllowanceAndPaysChosenReceiver() public {
        uint256 shares = 123_456_789;
        uint256 expectedAssets = pool.previewRedeem(shares);
        uint256 beforeShares = pool.balanceOf(lender);
        uint256 beforeCash = usdc.balanceOf(alice);
        vm.prank(lender);
        pool.approve(bob, shares - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, shares - 1, shares)
        );
        vm.prank(bob);
        pool.redeem(shares, alice, lender);
        assertEq(pool.balanceOf(lender), beforeShares);
        vm.prank(lender);
        pool.approve(bob, shares);
        vm.prank(bob);
        uint256 received = pool.redeem(shares, alice, lender);
        assertEq(received, expectedAssets);
        assertEq(usdc.balanceOf(alice), beforeCash + received);
        assertEq(pool.balanceOf(lender), beforeShares - shares);
        assertEq(pool.allowance(lender, bob), 0);
    }

    function test_unconfiguredPoolRejectsSettlementAndReserveCannotBeWithdrawn() public {
        CardPool standalone = new CardPool(address(this), usdc);
        vm.expectRevert(CardPool.LendingNotConfigured.selector);
        standalone.settle(0, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(standalone), 10e6);
        standalone.fundReserve(10e6);
        vm.stopPrank();
        assertEq(standalone.availableLiquidity(), 0);
        assertEq(standalone.totalAssets(), 0);
        assertEq(standalone.totalSupply(), 0);
        assertEq(standalone.maxWithdraw(bob), 0);
        vm.expectRevert(abi.encodeWithSelector(USDC4626.ERC4626ExceededMaxWithdraw.selector, bob, 1, 0));
        vm.prank(bob);
        standalone.withdraw(1, bob, bob);
        assertEq(usdc.balanceOf(address(standalone)), 10e6);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_repeatedDepositWithdrawAndMintRedeemCannotExtractDust(uint96 seed, uint96 donationSeed) public {
        uint256 donation = bound(donationSeed, 0, 10000e6);
        usdc.transfer(address(pool), donation);
        vm.startPrank(bob);
        pool.deposit(1000e6, bob); // Existing shares allow a withdrawal to burn one extra rounding unit.
        vm.stopPrank();
        uint256 initialCash = usdc.balanceOf(bob);
        uint256 initialShares = pool.balanceOf(bob);
        for (uint256 i; i < 8; ++i) {
            uint256 amount = bound(uint256(seed) + i, 1, 1000e6);
            uint256 beforeShares = pool.balanceOf(bob);
            vm.startPrank(bob);
            uint256 minted = pool.deposit(amount, bob);
            uint256 burned = pool.withdraw(amount, bob, bob);
            vm.stopPrank();
            assertGe(burned, minted, "withdraw may not burn fewer shares than deposit minted");
            assertLe(pool.balanceOf(bob), beforeShares);
            uint256 newShares = bound(uint256(seed) + i, 1e6, 1000e12);
            vm.startPrank(bob);
            uint256 paid = pool.mint(newShares, bob);
            uint256 received = pool.redeem(newShares, bob, bob);
            vm.stopPrank();
            assertLe(received, paid, "mint/redeem cannot create cash");
        }
        assertLe(usdc.balanceOf(bob), initialCash);
        assertLe(pool.balanceOf(bob), initialShares);
        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_maxExitQuotesAreExecutableAfterInterestAndDonations(uint32 secondsSeed, uint96 donationSeed)
        public
    {
        borrow(450e6);
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 30 days));
        usdc.transfer(address(pool), bound(donationSeed, 0, 1000e6));
        uint256 snapshot = vm.snapshotState();
        uint256 maxAssets = pool.maxWithdraw(lender);
        uint256 available = pool.availableLiquidity();
        uint256 beforeCash = usdc.balanceOf(lender);
        vm.prank(lender);
        pool.withdraw(maxAssets, lender, lender);
        assertEq(usdc.balanceOf(lender), beforeCash + maxAssets);
        assertLe(maxAssets, available);
        assertGe(usdc.balanceOf(address(pool)), pool.reserve());
        assertTrue(vm.revertToState(snapshot));
        uint256 maxShares = pool.maxRedeem(lender);
        vm.prank(lender);
        uint256 received = pool.redeem(maxShares, lender, lender);
        assertLe(received, available);
        assertEq(usdc.balanceOf(lender), beforeCash + received);
        assertGe(usdc.balanceOf(address(pool)), pool.reserve());
    }
}
