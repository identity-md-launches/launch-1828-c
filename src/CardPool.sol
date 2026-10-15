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
/// @dev NAV never moves inside a settlement. The reserve counts in NAV only as far as it was expected to cover
/// shortfalls that built up on the auction curve after the last checkpoint; anything a settlement collects above
/// the loan's mark is held back as reserve and reaches lenders only by covering later mark-downs.
contract CardPool is ERC4626, Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error LendingNotConfigured();
    error LendingAlreadyConfigured();
    error NotLending();
    error InsufficientLiquidity();
    error InvalidAmount();
    address public lending;
    uint256 public reserve;
    /// @notice Reserve counted in NAV at the last checkpoint, and the expected shortfall at that moment.
    uint256 public coveredCheckpoint;
    uint256 public shortfallCheckpoint;
    event LendingSet(address indexed lending);
    event Drawn(address indexed borrower, uint256 principal, uint256 fee);
    event Settled(uint256 payment, uint256 debt, uint256 reserveUsed, uint256 heldBack, uint256 uncoveredLoss);
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

    /// @notice Unreserved cash, receivables marked down the Dutch curve, and the reserve counted as covering them.
    function totalAssets() public view override returns (uint256) {
        if (lending == address(0)) return availableLiquidity();
        (uint256 receivable, uint256 expectedShortfall) = ICardDebt(lending).netReceivable();
        return availableLiquidity() + receivable + _covered(expectedShortfall);
    }

    /// @notice Part of the reserve counted in NAV: the expected shortfall it is set to absorb.
    function coveredReserve() public view returns (uint256) {
        if (lending == address(0)) return 0;
        (, uint256 expectedShortfall) = ICardDebt(lending).netReceivable();
        return _covered(expectedShortfall);
    }

    /// @dev Grows one for one with the expected shortfall since the last checkpoint, within the reserve and the
    /// shortfall itself. Reserve added later (fees, held-back recoveries, donations) therefore covers only
    /// mark-downs that come after it, and never re-rates a loss lenders have already carried.
    function _covered(uint256 expectedShortfall) private view returns (uint256) {
        uint256 grown = expectedShortfall > shortfallCheckpoint ? expectedShortfall - shortfallCheckpoint : 0;
        return Math.min(reserve, Math.min(expectedShortfall, coveredCheckpoint + grown));
    }

    /// @dev Freezes the counted reserve before the reserve changes, so the change itself moves no NAV.
    function _checkpoint() private {
        uint256 expectedShortfall;
        if (lending != address(0)) (, expectedShortfall) = ICardDebt(lending).netReceivable();
        coveredCheckpoint = _covered(expectedShortfall);
        shortfallCheckpoint = expectedShortfall;
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
        _checkpoint();
        reserve += fee;
        IERC20(asset()).safeTransfer(borrower, principal - fee);
        emit Drawn(borrower, principal, fee);
    }

    /// @notice Settles a loan so that NAV is exactly what it was the moment before.
    /// @dev Lending has already removed the loan from its book and reports how much `netReceivable` fell by.
    /// Reserve that NAV counted as covering this loan's shortfall is spent on it; what the payment collects above
    /// the loan's mark is held back as reserve, less any counted reserve the settlement leaves without a shortfall.
    /// @param payment Cash the pool receives now, at most `debt`.
    /// @param debt Contractual debt being closed.
    /// @param receivableReleased Drop in the receivable reported by `netReceivable`, at most `debt`.
    /// @param shortfallReleased Drop in the expected shortfall reported by `netReceivable`.
    function settle(uint256 payment, uint256 debt, uint256 receivableReleased, uint256 shortfallReleased)
        external
        onlyLending
        nonReentrant
    {
        if (payment > debt || receivableReleased > debt) revert InvalidAmount();
        (, uint256 shortfallAfter) = ICardDebt(lending).netReceivable();
        uint256 coveredBefore = _covered(shortfallAfter + shortfallReleased);
        uint256 used = Math.min(coveredBefore, debt - payment);
        uint256 coveredAfter = Math.min(coveredBefore - used, shortfallAfter);
        // Counted reserve that no longer backs any shortfall is released; the rest of the recovery is held back.
        uint256 heldBack = payment > receivableReleased ? payment - receivableReleased : 0;
        uint256 freed = coveredBefore - used - coveredAfter;
        heldBack = heldBack > freed ? heldBack - freed : 0;
        reserve = reserve - used + heldBack;
        coveredCheckpoint = coveredAfter;
        shortfallCheckpoint = shortfallAfter;
        if (payment != 0) IERC20(asset()).safeTransferFrom(msg.sender, address(this), payment);
        emit Settled(payment, debt, used, heldBack, debt - payment - used);
    }

    function fundReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        _checkpoint();
        reserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }
}
