// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardLending} from "src/CardLending.sol";
import {CardOracle} from "src/CardOracle.sol";
import {CardPool} from "src/CardPool.sol";
import {MockUSDC} from "src/MockUSDC.sol";
import {Admin} from "src/Admin.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CrossEntryAuctionReceiver is IERC721Receiver {
    CardLending private immutable lending;
    uint256 private immutable otherLoan;
    uint256 public blocked;

    constructor(CardLending lending_, uint256 otherLoan_) {
        lending = lending_;
        otherLoan = otherLoan_;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        bytes[] memory attempts = new bytes[](6);
        attempts[0] = abi.encodeCall(lending.borrow, (tokenId, 100e6));
        attempts[1] = abi.encodeCall(lending.repay, (otherLoan));
        attempts[2] = abi.encodeCall(lending.extend, (otherLoan, type(uint16).max));
        attempts[3] = abi.encodeCall(lending.liquidate, (otherLoan));
        attempts[4] = abi.encodeCall(lending.buy, (otherLoan, type(uint256).max, address(this)));
        attempts[5] = abi.encodeCall(lending.claimSurplus, (address(this)));
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok, bytes memory reason) = address(lending).call(attempts[i]);
            require(!ok, "reentrant entry succeeded");
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)),
                "failure did not come from reentrancy guard"
            );
            ++blocked;
        }
        return this.onERC721Received.selector;
    }
}

contract CardLendingEdgesTest is Fixture {
    function test_NFTReceiverCannotReenterAnyLendingValuePath() public {
        uint256 first = borrow(400e6);
        uint256 otherToken = nft.mint(alice, cardMetadata("other active loan"));
        vm.prank(alice);
        uint256 second = lending.borrow(otherToken, 300e6);
        vm.warp(getLoan(first).maturity);
        lending.liquidate(first);
        CrossEntryAuctionReceiver receiver = new CrossEntryAuctionReceiver(lending, second);
        bytes32 untouchedLoan = keccak256(abi.encode(lending.loan(second)));
        uint256 quote = lending.auctionPrice(first);
        vm.prank(bob);
        lending.buy(first, quote, address(receiver));
        assertEq(receiver.blocked(), 6);
        assertEq(nft.ownerOf(tokenId), address(receiver));
        assertEq(nft.ownerOf(otherToken), address(lending));
        assertEq(keccak256(abi.encode(lending.loan(second))), untouchedLoan);
        assertEq(lending.nextLoanId(), 3);
    }

    function test_originationFeeRoundsUpAtEachCentBoundaryAndBorrowCanRepeat() public {
        lending.setAPR(0);
        deliverPrice(1000);
        uint256[6] memory amounts = [uint256(2), 99, 100, 101, 199, 200];
        uint256[6] memory fees = [uint256(1), 1, 1, 2, 2, 2];
        uint256 cumulativeFee;
        uint256 beforeNAV = pool.totalAssets();
        uint256 borrowerCash = usdc.balanceOf(alice);
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(alice);
            uint256 id = lending.borrow(tokenId, amounts[i]);
            assertEq(id, i + 1);
            cumulativeFee += fees[i];
            assertEq(pool.reserve(), cumulativeFee);
            assertEq(lending.debtOf(id), amounts[i]);
            vm.prank(alice);
            lending.repay(id);
            assertEq(lending.collateralLoan(tokenId), 0);
            assertEq(nft.ownerOf(tokenId), alice);
            assertEq(usdc.balanceOf(alice), borrowerCash - cumulativeFee);
            assertEq(pool.totalAssets(), beforeNAV, "fee is segregated, not lender yield");
        }
        assertEq(lending.activePrincipal(), 0);
        assertEq(lending.interestNumerator(), 0);
    }

    function test_uint256MaximumBorrowFailsLTVBeforeAnyMovement() public {
        deliverPrice(1000);
        uint256 beforeCash = usdc.balanceOf(alice);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.borrow(tokenId, type(uint256).max);
        assertEq(usdc.balanceOf(alice), beforeCash);
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(lending.nextLoanId(), 1);
        assertEq(lending.totalDebt(), 0);
    }

    function test_maximumOracleUSDScalesAndSupportsExact45PercentBorrow() public {
        lending.setAPR(0);
        uint256 dollars = oracle.MAX_USD();
        deliverPrice(dollars);
        uint256 gross = dollars * 1e6 * 45 / 100;
        usdc.mint(lender, gross);
        vm.prank(lender);
        pool.deposit(gross, lender);
        vm.expectRevert(CardLending.TooMuchDebt.selector);
        vm.prank(alice);
        lending.borrow(tokenId, gross + 1);
        vm.prank(alice);
        uint256 id = lending.borrow(tokenId, gross);
        assertEq(lending.debtOf(id), gross);
        assertEq(pool.reserve(), gross / 100);
        usdc.mint(alice, gross / 100);
        vm.prank(alice);
        lending.repay(id);
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(lending.totalDebt(), 0);
    }

    function test_unconfiguredAndWrongAssetPoolCannotCreateLoan() public {
        CardPool unconfigured = new CardPool(address(this), usdc);
        CardLending candidate = new CardLending(address(this), nft, unconfigured, oracle, usdc);
        vm.expectRevert(CardLending.DependenciesMismatch.selector);
        vm.prank(alice);
        candidate.borrow(tokenId, 1e6);
        MockUSDC otherAsset = new MockUSDC(address(this));
        CardPool wrongAsset = new CardPool(address(this), otherAsset);
        candidate = new CardLending(address(this), nft, wrongAsset, oracle, usdc);
        wrongAsset.setLending(address(candidate));
        vm.expectRevert(CardLending.DependenciesMismatch.selector);
        vm.prank(alice);
        candidate.borrow(tokenId, 1e6);
        assertEq(candidate.nextLoanId(), 1);
        assertEq(nft.ownerOf(tokenId), alice);
    }

    function test_poolPauseRollsBackBorrowIncludingNFTTransferAndLoanId() public {
        deliverPrice(1000);
        pool.pause();
        uint256 cash = usdc.balanceOf(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        lending.borrow(tokenId, 400e6);
        assertEq(lending.nextLoanId(), 1);
        assertEq(lending.collateralLoan(tokenId), 0);
        assertEq(lending.activePrincipal(), 0);
        assertEq(lending.rateWeight(), 0);
        assertEq(pool.reserve(), 0);
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(usdc.balanceOf(alice), cash);
    }

    function test_failedExtensionRestoresAPRAccrualAndMaturity() public {
        uint256 id = borrow(400e6);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        deliverPrice(2000);
        lending.setAPR(2400);
        vm.prank(alice);
        usdc.approve(address(lending), 0);
        bytes32 beforeState = _accountingHash(id);
        uint256 interest = lending.interestOf(id);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lending), 0, interest)
        );
        vm.prank(alice);
        lending.extend(id, type(uint16).max);
        assertEq(_accountingHash(id), beforeState, "failed interest payment must roll back renewal");
        vm.prank(alice);
        usdc.approve(address(lending), interest);
        vm.prank(alice);
        lending.extend(id, type(uint16).max);
        assertEq(getLoan(id).aprBps, 2400);
        assertEq(lending.interestOf(id), 0);
        assertEq(usdc.allowance(address(lending), address(pool)), 0);
    }

    function test_onlyBorrowerCanExtendEvenWithNFTApproval() public {
        uint256 id = borrow(400e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        deliverPrice(2000);
        // Alice's original approval let lending take custody; it confers no loan authority on Bob.
        vm.expectRevert(CardLending.NotBorrower.selector);
        vm.prank(bob);
        lending.extend(id, type(uint16).max);
        assertEq(getLoan(id).borrower, alice);
        assertEq(nft.ownerOf(tokenId), address(lending));
    }

    function test_freshHealthyCollateralBecomesLiquidatableExactlyAtMaturity() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        uint256 maturity = getLoan(id).maturity;
        vm.warp(maturity - 1);
        deliverPrice(10_000);
        vm.expectRevert(CardLending.NotLiquidatable.selector);
        lending.liquidate(id);
        vm.warp(maturity);
        vm.expectRevert(CardLending.WrongState.selector);
        vm.prank(alice);
        lending.extend(id, type(uint16).max);
        lending.liquidate(id);
        assertEq(getLoan(id).auctionStartedAt, maturity);
        assertEq(lending.debtOf(id), 400e6);
    }

    function test_unknownAndClosedLoansRejectEveryLifecycleAction() public {
        _assertTerminal(0);
        _assertTerminal(type(uint256).max);
        uint256 id = borrow(400e6);
        vm.prank(alice);
        lending.repay(id);
        _assertTerminal(id);
        assertEq(nft.ownerOf(tokenId), alice);
    }

    function test_oddDebtAuctionRoundsUpAtStartMidpointFloorAndRemainsFrozen() public {
        lending.setAPR(0);
        uint256 id = borrow(3);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 start = getLoan(id).auctionStartedAt;
        assertEq(lending.auctionPrice(id), 4);
        vm.warp(start + 12 hours);
        assertEq(lending.auctionPrice(id), 3);
        vm.warp(start + 1 days - 1);
        assertEq(lending.auctionPrice(id), 2);
        vm.warp(start + 1 days);
        assertEq(lending.auctionPrice(id), 2);
        vm.warp(start + 1000 days);
        assertEq(lending.auctionPrice(id), 2);
        assertEq(lending.totalDebt(), 3);
        assertEq(lending.interestNumerator(), 0);
        // Written off: the three-unit debt is carried at zero, with the one-unit reserve as expected cover.
        (uint256 receivable, uint256 shortfall) = lending.netReceivable();
        assertEq(receivable, 0);
        assertEq(shortfall, 3);
        assertEq(lending.auctionMark(id), 0);
        assertEq(pool.totalAssets(), 10_000e6 - 2, "written-off auction counts only its reserve cover");
        vm.prank(bob);
        lending.buy(id, 2, bob);
        assertEq(pool.reserve(), 0);
        assertEq(pool.totalAssets(), 10_000e6, "floor sale recovers two units, reserve covers the third");
        (receivable, shortfall) = lending.netReceivable();
        assertEq(receivable + shortfall, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_auctionQuoteIsSmallestIntegerAtOrAboveLinearPrice(uint96 debtSeed, uint32 elapsedSeed) public {
        uint256 amount = bound(debtSeed, 2, 450e6);
        uint256 elapsed = bound(elapsedSeed, 0, 2 days);
        lending.setAPR(0);
        uint256 id = borrow(amount);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 start = getLoan(id).auctionStartedAt;
        vm.warp(start + elapsed);
        uint256 quote = lending.auctionPrice(id);
        uint256 t = elapsed < 1 days ? elapsed : 1 days;
        // Rational inequalities detect rounding errors without using the implementation's mulDiv.
        uint256 exactNumerator = amount * (12 * 1 days - 7 * t);
        uint256 divisor = 10 * 1 days;
        assertGe(quote * divisor, exactNumerator);
        assertLt((quote - 1) * divisor, exactNumerator);
        assertEq(lending.debtOf(id), amount);
        vm.warp(start + elapsed + 1);
        assertLe(lending.auctionPrice(id), quote);
    }

    function test_buyInvalidReceiverMissingAllowanceAndLowBalanceAreAtomic() public {
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        uint256 price = lending.auctionPrice(id);
        bytes32 beforeState = _accountingHash(id);
        vm.expectRevert(Admin.InvalidAddress.selector);
        vm.prank(bob);
        lending.buy(id, price, address(0));
        vm.expectRevert(Admin.InvalidAddress.selector);
        vm.prank(bob);
        lending.buy(id, price, address(lending));
        vm.prank(bob);
        usdc.approve(address(lending), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lending), 0, price)
        );
        vm.prank(bob);
        lending.buy(id, price, bob);
        assertEq(_accountingHash(id), beforeState);
        vm.startPrank(bob);
        usdc.approve(address(lending), type(uint256).max);
        usdc.transfer(lender, 100_000e6);
        vm.stopPrank();
        beforeState = _accountingHash(id);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, price));
        vm.prank(bob);
        lending.buy(id, price, bob);
        assertEq(_accountingHash(id), beforeState);
        assertEq(lending.surplus(alice), 0);
        assertEq(nft.ownerOf(tokenId), address(lending));
    }

    function test_surplusCannotBeClaimedByBuyerOrLostOnInvalidRecipient() public {
        lending.setAPR(0);
        uint256 id = borrow(400e6);
        vm.warp(getLoan(id).maturity);
        lending.liquidate(id);
        vm.prank(bob);
        lending.buy(id, 480e6, bob);
        vm.expectRevert(CardLending.InvalidAmount.selector);
        vm.prank(bob);
        lending.claimSurplus(bob);
        vm.expectRevert(Admin.InvalidAddress.selector);
        vm.prank(alice);
        lending.claimSurplus(address(0));
        assertEq(lending.totalSurplus(), 80e6);
        assertEq(lending.surplus(alice), 80e6);
        uint256 receiverCash = usdc.balanceOf(lender);
        vm.prank(alice);
        lending.claimSurplus(lender);
        assertEq(usdc.balanceOf(lender), receiverCash + 80e6);
        assertEq(usdc.balanceOf(address(lending)), 0);
    }

    function _assertTerminal(uint256 id) internal {
        assertEq(lending.debtOf(id), 0);
        assertEq(lending.interestOf(id), 0);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.repay(id);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.extend(id, type(uint16).max);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.liquidate(id);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.auctionPrice(id);
        vm.expectRevert(CardLending.WrongState.selector);
        lending.buy(id, type(uint256).max, bob);
    }

    function _accountingHash(uint256 id) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                lending.loan(id),
                lending.activePrincipal(),
                lending.interestNumerator(),
                lending.rateWeight(),
                lending.frozenDebt(),
                lending.lastAccrual(),
                lending.totalSurplus(),
                pool.reserve(),
                usdc.balanceOf(address(pool)),
                usdc.balanceOf(address(lending))
            )
        );
    }
}
