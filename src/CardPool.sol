// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {USDC4626 as ERC4626} from "./base/USDC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Guarded} from "./Guarded.sol";
import {ICardDebt} from "./interfaces/ICardDebt.sol";

/// @notice ERC-4626 shares in cash plus accrued loan receivables. Reserved cash belongs to the loss buffer.
contract CardPool is ERC4626, Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error LendingNotConfigured();
    error LendingAlreadyConfigured();
    error NotLending();
    error InsufficientLiquidity();
    error InvalidAmount();
    address public lending;
    uint256 public reserve;
    event LendingSet(address indexed lending);
    event Drawn(address indexed borrower, uint256 principal, uint256 fee);
    event Settled(uint256 payment, uint256 debt, uint256 reserveUsed, uint256 uncoveredLoss);
    event ReserveFunded(address indexed funder, uint256 amount);

    // Fixed six-decimal asset metadata keeps constructors independent of deployment order.
    constructor(address admin, IERC20 usdc) ERC20("CardVault Pool Share", "cvUSDC") ERC4626(usdc) Guarded(admin) {
        if (address(usdc) == address(0)) revert InvalidAddress();
    }

    /// @notice One-time wiring prevents an admin from replacing the borrower with an arbitrary cash drainer.
    function setLending(address next) external onlyOwner {
        if (lending != address(0)) revert LendingAlreadyConfigured();
        if (next.code.length == 0 || ICardDebt(next).pool() != address(this)) revert InvalidAddress();
        lending = next;
        emit LendingSet(next);
    }

    modifier onlyLending() {
        if (lending == address(0)) revert LendingNotConfigured();
        if (msg.sender != lending) revert NotLending();
        _;
    }

    function availableLiquidity() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - reserve;
    }

    /// @notice Unreserved cash, receivables marked down the Dutch curve, and the reserve expected to cover shortfalls.
    function totalAssets() public view override returns (uint256) {
        if (lending == address(0)) return availableLiquidity();
        (uint256 receivable, uint256 expectedShortfall) = ICardDebt(lending).netReceivable();
        return availableLiquidity() + receivable + Math.min(reserve, expectedShortfall);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function decimals() public pure override returns (uint8) {
        return 12;
    }

    function maxWithdraw(address holder) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(holder), availableLiquidity());
    }

    /// @dev Never advertises a dust amount that `redeem` would refuse.
    function maxRedeem(address holder) public view override returns (uint256) {
        uint256 shares = Math.min(balanceOf(holder), convertToShares(availableLiquidity()));
        return previewRedeem(shares) == 0 ? 0 : shares;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        if (assets == 0 || previewDeposit(assets) == 0) revert InvalidAmount();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        if (shares == 0) revert InvalidAmount();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address holder) public override nonReentrant returns (uint256) {
        if (assets == 0) revert InvalidAmount();
        return super.withdraw(assets, receiver, holder);
    }

    function redeem(uint256 shares, address receiver, address holder) public override nonReentrant returns (uint256) {
        if (shares == 0 || previewRedeem(shares) == 0) revert InvalidAmount();
        return super.redeem(shares, receiver, holder);
    }

    /// @dev Borrower receives principal minus fee, owes principal. Fee remains as segregated reserve cash.
    function draw(address borrower, uint256 principal, uint256 fee) external onlyLending whenNotPaused nonReentrant {
        if (principal == 0 || fee >= principal) revert InvalidAmount();
        if (principal > availableLiquidity()) revert InsufficientLiquidity();
        reserve += fee;
        IERC20(asset()).safeTransfer(borrower, principal - fee);
        emit Drawn(borrower, principal, fee);
    }

    /// @dev Lending removes the corresponding receivable before calling; this function pulls actual cash.
    function settle(uint256 payment, uint256 debt) external onlyLending nonReentrant {
        if (payment > debt) revert InvalidAmount();
        uint256 shortfall = debt - payment;
        uint256 covered = Math.min(reserve, shortfall);
        reserve -= covered;
        if (payment != 0) IERC20(asset()).safeTransferFrom(msg.sender, address(this), payment);
        emit Settled(payment, debt, covered, shortfall - covered);
    }

    function fundReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }
}
