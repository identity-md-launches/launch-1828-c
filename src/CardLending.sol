// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Guarded} from "./Guarded.sol";
import {MockCardNFT} from "./MockCardNFT.sol";
import {CardOracle} from "./CardOracle.sol";
import {CardPool} from "./CardPool.sol";

contract CardLending is Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Active,
        Auction,
        Closed
    }

    struct Loan {
        address borrower;
        uint256 tokenId;
        bytes32 classId;
        uint256 principal;
        uint64 startedAt;
        uint64 maturity;
        uint64 priceIssuedAt;
        uint16 aprBps;
        State state;
        uint64 auctionStartedAt;
        uint256 auctionDebt;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 4500;
    uint256 public constant LIQUIDATION_LTV_BPS = 6000;
    uint256 public constant ORIGINATION_FEE_BPS = 100;
    uint256 public constant TERM = 30 days;
    uint256 public constant AUCTION_DURATION = 1 days;
    uint256 public constant INTEREST_DENOMINATOR = BPS * 365 days;
    uint16 public aprBps = 1200;
    MockCardNFT public immutable nft;
    CardPool public immutable pool;
    CardOracle public immutable oracle;
    IERC20 public immutable usdc;
    uint256 public nextLoanId = 1;
    mapping(uint256 => Loan) public loans;
    mapping(uint256 => uint256) public collateralLoan;
    mapping(address => uint256) public surplus;
    uint256 public totalSurplus;

    // Sum exact interest numerators, rounding only when publishing NAV or settling a loan.
    uint256 public activePrincipal;
    uint256 public interestNumerator;
    uint256 public rateWeight;
    uint256 public frozenDebt;
    uint256 public lastAccrual;

    error InvalidAmount();
    error NotBorrower();
    error WrongState();
    error TooMuchDebt();
    error PriceNotNewer();
    error NotLiquidatable();
    error Slippage();
    error InvalidRate();
    error DependenciesMismatch();

    event Borrowed(
        uint256 indexed loanId, uint256 indexed tokenId, address indexed borrower, uint256 principal, uint256 fee
    );
    event Repaid(uint256 indexed loanId, address indexed payer, uint256 debt);
    event Extended(uint256 indexed loanId, uint64 maturity, uint16 aprBps, uint256 interestPaid);
    event AuctionStarted(uint256 indexed loanId, uint256 debt, uint64 startedAt);
    event Purchased(
        uint256 indexed loanId, address indexed buyer, address indexed receiver, uint256 price, uint256 surplus
    );
    event SurplusClaimed(address indexed borrower, address indexed receiver, uint256 amount);
    event RateSet(uint16 aprBps);

    constructor(address admin, MockCardNFT nft_, CardPool pool_, CardOracle oracle_, IERC20 usdc_) Guarded(admin) {
        if (
            address(nft_) == address(0) || address(pool_) == address(0) || address(oracle_) == address(0)
                || address(usdc_) == address(0)
        ) revert InvalidAddress();
        nft = nft_;
        pool = pool_;
        oracle = oracle_;
        usdc = usdc_;
        lastAccrual = block.timestamp;
    }

    /// @notice Gross debt is amount; the borrower receives amount less the reserve fee.
    function borrow(uint256 tokenId, uint256 amount) external nonReentrant whenNotPaused returns (uint256 id) {
        if (pool.asset() != address(usdc) || pool.lending() != address(this)) revert DependenciesMismatch();
        if (amount == 0) revert InvalidAmount();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotBorrower();
        bytes32 cardClass = nft.classId(tokenId);
        CardOracle.Price memory p = oracle.freshPrice(cardClass);
        if (amount > Math.mulDiv(p.price, MAX_LTV_BPS, BPS)) revert TooMuchDebt();
        uint256 fee = Math.mulDiv(amount, ORIGINATION_FEE_BPS, BPS, Math.Rounding.Ceil);
        if (fee >= amount) revert InvalidAmount();
        _accrue();
        id = nextLoanId++;
        loans[id] = Loan({
            borrower: msg.sender,
            tokenId: tokenId,
            classId: cardClass,
            principal: amount,
            startedAt: uint64(block.timestamp),
            maturity: uint64(block.timestamp + TERM),
            priceIssuedAt: p.issuedAt,
            aprBps: aprBps,
            state: State.Active,
            auctionStartedAt: 0,
            auctionDebt: 0
        });
        collateralLoan[tokenId] = id;
        activePrincipal += amount;
        rateWeight += amount * aprBps;
        // No receiver hook on inbound custody; this contract has no generic NFT receiver or rescue backdoor.
        nft.transferFrom(msg.sender, address(this), tokenId);
        pool.draw(msg.sender, amount, fee);
        emit Borrowed(id, tokenId, msg.sender, amount, fee);
    }

    function loan(uint256 id) external view returns (Loan memory) {
        return loans[id];
    }

    function interestOf(uint256 id) public view returns (uint256) {
        Loan storage l = loans[id];
        if (l.state != State.Active) return 0;
        return _loanInterestNumerator(l) / INTEREST_DENOMINATOR;
    }

    function debtOf(uint256 id) public view returns (uint256) {
        Loan storage l = loans[id];
        if (l.state == State.Auction) return l.auctionDebt;
        if (l.state == State.Active) return l.principal + interestOf(id);
        return 0;
    }

    function totalDebt() external view returns (uint256) {
        return activePrincipal + frozenDebt + (interestNumerator + rateWeight * (block.timestamp - lastAccrual))
            / INTEREST_DENOMINATOR;
    }

    /// @notice Anyone may repay in full, including while paused or at auction; the NFT always returns to its borrower.
    function repay(uint256 id) external nonReentrant {
        Loan storage l = loans[id];
        if (l.state != State.Active && l.state != State.Auction) revert WrongState();
        uint256 debt = debtOf(id);
        _accrue();
        if (l.state == State.Active) _removeActive(l);
        else frozenDebt -= debt;
        l.state = State.Closed;
        delete collateralLoan[l.tokenId];
        _payPool(msg.sender, debt, debt);
        // transferFrom allows contract borrowers to recover even if their receiver hook later changes.
        nft.transferFrom(address(this), l.borrower, l.tokenId);
        emit Repaid(id, msg.sender, debt);
    }

    /// @notice Pay accrued interest and renew for 30 days at the current owner-set APR. No additional origination fee.
    function extend(uint256 id) external nonReentrant whenNotPaused {
        Loan storage l = loans[id];
        if (l.state != State.Active || block.timestamp >= l.maturity) revert WrongState();
        if (msg.sender != l.borrower) revert NotBorrower();
        CardOracle.Price memory p = oracle.freshPrice(l.classId);
        if (p.issuedAt <= l.priceIssuedAt) revert PriceNotNewer();
        uint256 interest = interestOf(id);
        if (l.principal + interest > Math.mulDiv(p.price, MAX_LTV_BPS, BPS)) revert TooMuchDebt();
        _accrue();
        interestNumerator -= _loanInterestNumerator(l);
        rateWeight -= l.principal * l.aprBps;
        l.aprBps = aprBps;
        rateWeight += l.principal * aprBps;
        l.startedAt = uint64(block.timestamp);
        l.maturity = uint64(block.timestamp + TERM);
        l.priceIssuedAt = p.issuedAt;
        _payPool(msg.sender, interest, interest);
        emit Extended(id, l.maturity, aprBps, interest);
    }

    /// @notice Anyone can start an auction at maturity, or after a newer fresh price puts debt strictly above 60%.
    function liquidate(uint256 id) external nonReentrant whenNotPaused {
        Loan storage l = loans[id];
        if (l.state != State.Active) revert WrongState();
        uint256 debt = debtOf(id);
        if (block.timestamp < l.maturity) {
            CardOracle.Price memory p = oracle.freshPrice(l.classId);
            if (p.issuedAt <= l.priceIssuedAt) revert PriceNotNewer();
            if (debt <= Math.mulDiv(p.price, LIQUIDATION_LTV_BPS, BPS)) revert NotLiquidatable();
        }
        _accrue();
        _removeActive(l);
        frozenDebt += debt;
        l.state = State.Auction;
        l.auctionStartedAt = uint64(block.timestamp);
        l.auctionDebt = debt;
        emit AuctionStarted(id, debt, l.auctionStartedAt);
    }

    /// @notice Continuous linear Dutch price; after 24h it remains at the 50% floor until sold or repaid.
    function auctionPrice(uint256 id) public view returns (uint256) {
        Loan storage l = loans[id];
        if (l.state != State.Auction) revert WrongState();
        uint256 elapsed = Math.min(block.timestamp - l.auctionStartedAt, AUCTION_DURATION);
        uint256 numerator = 12_000 * AUCTION_DURATION - 7_000 * elapsed;
        return Math.mulDiv(l.auctionDebt, numerator, BPS * AUCTION_DURATION, Math.Rounding.Ceil);
    }

    function buy(uint256 id, uint256 maxPrice, address receiver) external nonReentrant {
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        uint256 price = auctionPrice(id);
        if (price > maxPrice) revert Slippage();
        Loan storage l = loans[id];
        uint256 debt = l.auctionDebt;
        l.state = State.Closed;
        frozenDebt -= debt;
        delete collateralLoan[l.tokenId];
        uint256 paidToPool = Math.min(price, debt);
        uint256 extra = price - paidToPool;
        if (extra != 0) {
            surplus[l.borrower] += extra;
            totalSurplus += extra;
        }
        usdc.safeTransferFrom(msg.sender, address(this), price);
        usdc.forceApprove(address(pool), paidToPool);
        pool.settle(paidToPool, debt);
        usdc.forceApprove(address(pool), 0);
        nft.safeTransferFrom(address(this), receiver, l.tokenId);
        emit Purchased(id, msg.sender, receiver, price, extra);
    }

    function claimSurplus(address receiver) external nonReentrant {
        if (receiver == address(0)) revert InvalidAddress();
        uint256 amount = surplus[msg.sender];
        if (amount == 0) revert InvalidAmount();
        surplus[msg.sender] = 0;
        totalSurplus -= amount;
        usdc.safeTransfer(receiver, amount);
        emit SurplusClaimed(msg.sender, receiver, amount);
    }

    function setAPR(uint16 next) external onlyOwner {
        if (next > BPS) revert InvalidRate();
        aprBps = next;
        emit RateSet(next);
    }

    function _payPool(address payer, uint256 payment, uint256 debt) private {
        if (payment != 0) usdc.safeTransferFrom(payer, address(this), payment);
        usdc.forceApprove(address(pool), payment);
        pool.settle(payment, debt);
        usdc.forceApprove(address(pool), 0);
    }

    function _accrue() private {
        interestNumerator += rateWeight * (block.timestamp - lastAccrual);
        lastAccrual = block.timestamp;
    }

    function _loanInterestNumerator(Loan storage l) private view returns (uint256) {
        return l.principal * l.aprBps * (block.timestamp - l.startedAt);
    }

    function _removeActive(Loan storage l) private {
        activePrincipal -= l.principal;
        interestNumerator -= _loanInterestNumerator(l);
        rateWeight -= l.principal * l.aprBps;
    }
}
