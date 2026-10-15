// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CardVaultHandler} from "./CardVaultHandler.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CardVaultInvariantTest is Test {
    CardVaultHandler internal handler;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        handler = new CardVaultHandler();
        bytes4[] memory selectors = new bytes4[](14);
        selectors[13] = handler.sandwich.selector;
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.borrow.selector;
        selectors[5] = handler.repay.selector;
        selectors[6] = handler.extend.selector;
        selectors[7] = handler.liquidate.selector;
        selectors[8] = handler.buy.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.elapse.selector;
        selectors[11] = handler.admin.selector;
        selectors[12] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_cashDebtSharesReservesSurplusAndCollateralAgree() public view {
        handler.checkAccounting();
    }

    function afterInvariant() public {
        handler.closeAllAndExit();
    }

    /// @dev A deterministic witness exercises every handler and both auction outcomes;
    /// it prevents a passing campaign composed only of early returns from looking useful.
    function test_handlerReachesEveryEconomicTransition() public {
        handler.deposit(1, 20_000e6, false);
        handler.deposit(2, 10_000e6, true);
        handler.withdraw(1, 10e6, false);
        handler.withdraw(2, 10e12, true);
        handler.transfer(1, 2, 10e12, true);
        handler.transfer(1, 2, 10e6, false);
        handler.donate(3, 5e6, true);
        handler.donate(3, 1e6, false);
        handler.borrow(1, 400e6);
        handler.borrow(4, 300e6);
        handler.elapse(10 days);
        handler.admin(1600, false, false);
        handler.extend(0);
        handler.repay(1, 3);
        handler.liquidate(0, true);
        handler.buy(0, 2, 3);
        handler.claim(0, 1);
        handler.borrow(2, 400e6);
        handler.liquidate(2, false);
        handler.elapse(1 days);
        handler.buy(2, 2, 3);
        // Sandwiched settlements in every phase: at par, mid-descent, written off, and an active repayment.
        handler.borrow(5, 400e6);
        handler.borrow(8, 300e6);
        handler.borrow(11, 200e6);
        handler.liquidate(3, false);
        handler.sandwich(3, 1, 5_000e6, false);
        handler.liquidate(4, false);
        handler.elapse(12 hours);
        handler.sandwich(4, 2, 5_000e6, true);
        handler.liquidate(5, false);
        handler.elapse(2 days);
        handler.sandwich(5, 1, 5_000e6, false);
        handler.borrow(3, 100e6);
        handler.sandwich(6, 3, 5_000e6, true);
        handler.admin(0, true, true);
        handler.withdraw(0, 1e6, false);
        handler.admin(1200, false, false);
        for (uint256 i; i < 20; ++i) {
            handler.roundTrip(1, 1e6 + i, i % 2 == 0);
        }
        handler.checkAccounting();
        assertGt(handler.calls(handler.borrow.selector), 2);
        assertEq(handler.calls(handler.extend.selector), 1);
        assertEq(handler.calls(handler.repay.selector), 1);
        assertEq(handler.calls(handler.buy.selector), 2);
        assertEq(handler.calls(handler.claim.selector), 1);
        assertGt(handler.reserveSpent(), 0);
        assertGt(handler.reserveHeld(), 0);
        assertEq(handler.sandwiches(), 4);
        assertEq(handler.calls(handler.roundTrip.selector), 20);
    }
}
