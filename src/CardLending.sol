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

    /// @dev Memory projection of the auction book at a point in time; see `_projectBook`.
    struct Book {
        uint256 parHead;
        uint256 descentHead;
        uint256 decayHead;
        uint256 parDebt;
        uint256 descentDebt;
        uint256 descentWeight;
        uint256 decayDebt;
        uint256 decayWeight;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 4500;
    uint256 public constant LIQUIDATION_LTV_BPS = 6000;
    uint256 public constant ORIGINATION_FEE_BPS = 100;
    uint256 public constant TERM = 30 days;
    uint256 public constant AUCTION_DURATION = 1 days;
    uint256 public constant AUCTION_START_BPS = 12_000;
    uint256 public constant AUCTION_FLOOR_BPS = 5_000;
    /// @notice Seconds after an auction opens during which its price is still at or above the debt.
    uint256 public constant PAR_WINDOW =
        (AUCTION_START_BPS - BPS) * AUCTION_DURATION / (AUCTION_START_BPS - AUCTION_FLOOR_BPS);
    /// @notice An auction unsold at its floor is written down linearly to zero in pool NAV over this long.
    uint256 public constant WRITE_OFF_DELAY = 1 days;
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

    // Auction book: ids in liquidation order, so every phase change happens in queue order and the
    // aggregates below can be brought up to date lazily by walking from three heads.
    uint256[] public auctionQueue;
    uint256 public parHead;
    uint256 public descentHead;
    uint256 public decayHead;
    uint256 public parDebt;
    uint256 public descentDebt;
    uint256 public descentWeight;
    uint256 public decayDebt;
    uint256 public decayWeight;

    error InvalidAmount();
    error NotBorrower();
    error WrongState();
    error TooMuchDebt();
    error PriceNotNewer();
    error NotLiquidatable();
    error Slippage();
    error InvalidRate();
    error RateAboveLimit();
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

    /// @notice Interest owed so far, rounded up to a base unit so rounding never favours the borrower.
    function interestOf(uint256 id) public view returns (uint256) {
        Loan storage l = loans[id];
        if (l.state != State.Active) return 0;
        return Math.ceilDiv(_loanInterestNumerator(l), INTEREST_DENOMINATOR);
    }

    function debtOf(uint256 id) public view returns (uint256) {
        Loan storage l = loans[id];
        if (l.state == State.Auction) return l.auctionDebt;
        if (l.state == State.Active) return l.principal + interestOf(id);
        return 0;
    }

    /// @notice Contractual debt of every open loan: active principal and interest plus frozen auction debt.
    function totalDebt() external view returns (uint256) {
        return activePrincipal + frozenDebt + _accruedInterest();
    }

    /// @notice What the pool carries as receivable, and how much of the frozen debt it expects to lose.
    /// @dev Auction loans are marked at min(debt, current Dutch price): par for the first `PAR_WINDOW`, then
    /// down the curve to 50% at `AUCTION_DURATION`, then linearly from the floor to zero over `WRITE_OFF_DELAY`.
    /// The mark is continuous in time, so no lender can time an exit around a step in it.
    function netReceivable() external view returns (uint256 receivable, uint256 expectedShortfall) {
        return _marks();
    }

    /// @notice Current NAV mark of one auction loan; zero once written off or when no auction is open.
    function auctionMark(uint256 id) external view returns (uint256) {
        Loan storage l = loans[id];
        if (l.state != State.Auction) return 0;
        uint256 elapsed = block.timestamp - l.auctionStartedAt;
        if (elapsed < AUCTION_DURATION) return Math.min(l.auctionDebt, auctionPrice(id));
        if (elapsed >= AUCTION_DURATION + WRITE_OFF_DELAY) return 0;
        uint256 remaining = AUCTION_DURATION + WRITE_OFF_DELAY - elapsed;
        return Math.ceilDiv(l.auctionDebt * remaining, 2 * WRITE_OFF_DELAY);
    }

    /// @notice Anyone may repay in full, including while paused or at auction; the NFT always returns to its borrower.
    function repay(uint256 id) external nonReentrant {
        Loan storage l = loans[id];
        if (l.state != State.Active && l.state != State.Auction) revert WrongState();
        uint256 debt = debtOf(id);
        _accrue();
        (uint256 receivableBefore, uint256 shortfallBefore) = _marks();
        if (l.state == State.Active) _removeActive(l);
        else _removeAuction(l);
        l.state = State.Closed;
        delete collateralLoan[l.tokenId];
        if (debt != 0) usdc.safeTransferFrom(msg.sender, address(this), debt);
        _settle(debt, debt, receivableBefore, shortfallBefore);
        // transferFrom allows contract borrowers to recover even if their receiver hook later changes.
        nft.transferFrom(address(this), l.borrower, l.tokenId);
        emit Repaid(id, msg.sender, debt);
    }

    /// @notice Pay accrued interest and renew for 30 days at the current owner-set APR. No additional origination fee.
    /// @param maxAprBps Highest APR the borrower accepts for the new term; protects against a rate change landing first.
    function extend(uint256 id, uint16 maxAprBps) external nonReentrant whenNotPaused {
        Loan storage l = loans[id];
        if (l.state != State.Active || block.timestamp >= l.maturity) revert WrongState();
        if (msg.sender != l.borrower) revert NotBorrower();
        if (aprBps > maxAprBps) revert RateAboveLimit();
        CardOracle.Price memory p = oracle.freshPrice(l.classId);
        if (p.issuedAt <= l.priceIssuedAt) revert PriceNotNewer();
        // Interest is paid in this call, so the debt that survives the renewal is the principal alone.
        if (l.principal > Math.mulDiv(p.price, MAX_LTV_BPS, BPS)) revert TooMuchDebt();
        uint256 interest = interestOf(id);
        _accrue();
        (uint256 receivableBefore, uint256 shortfallBefore) = _marks();
        interestNumerator -= _loanInterestNumerator(l);
        rateWeight -= l.principal * l.aprBps;
        l.aprBps = aprBps;
        rateWeight += l.principal * aprBps;
        l.startedAt = uint64(block.timestamp);
        l.maturity = uint64(block.timestamp + TERM);
        l.priceIssuedAt = p.issuedAt;
        if (interest != 0) usdc.safeTransferFrom(msg.sender, address(this), interest);
        _settle(interest, interest, receivableBefore, shortfallBefore);
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
        _syncAuctions();
        _removeActive(l);
        frozenDebt += debt;
        parDebt += debt;
        auctionQueue.push(id);
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
        uint256 numerator = AUCTION_START_BPS * AUCTION_DURATION - (AUCTION_START_BPS - AUCTION_FLOOR_BPS) * elapsed;
        return Math.mulDiv(l.auctionDebt, numerator, BPS * AUCTION_DURATION, Math.Rounding.Ceil);
    }

    function buy(uint256 id, uint256 maxPrice, address receiver) external nonReentrant {
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        uint256 price = auctionPrice(id);
        if (price > maxPrice) revert Slippage();
        Loan storage l = loans[id];
        uint256 debt = l.auctionDebt;
        (uint256 receivableBefore, uint256 shortfallBefore) = _marks();
        _removeAuction(l);
        l.state = State.Closed;
        delete collateralLoan[l.tokenId];
        uint256 paidToPool = Math.min(price, debt);
        uint256 extra = price - paidToPool;
        if (extra != 0) {
            surplus[l.borrower] += extra;
            totalSurplus += extra;
        }
        usdc.safeTransferFrom(msg.sender, address(this), price);
        _settle(paidToPool, debt, receivableBefore, shortfallBefore);
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

    /// @notice Permissionless: records auction phase changes so later NAV reads walk fewer entries.
    function syncAuctions() external {
        _syncAuctions();
    }

    function auctionQueueLength() external view returns (uint256) {
        return auctionQueue.length;
    }

    function setAPR(uint16 next) external onlyOwner {
        if (next > BPS) revert InvalidRate();
        aprBps = next;
        emit RateSet(next);
    }

    /// @dev Hands `payment` already held here to the pool, telling it exactly how far the book just fell.
    function _settle(uint256 payment, uint256 debt, uint256 receivableBefore, uint256 shortfallBefore) private {
        (uint256 receivableAfter, uint256 shortfallAfter) = _marks();
        usdc.forceApprove(address(pool), payment);
        pool.settle(payment, debt, receivableBefore - receivableAfter, shortfallBefore - shortfallAfter);
        usdc.forceApprove(address(pool), 0);
    }

    /// @dev Receivable and expected shortfall as the pool reads them, from the book projected to now.
    function _marks() private view returns (uint256 receivable, uint256 expectedShortfall) {
        uint256 mark = _auctionMark(_projectBook(block.timestamp), block.timestamp);
        receivable = activePrincipal + _accruedInterest() + mark;
        expectedShortfall = frozenDebt - mark;
    }

    function _accrue() private {
        interestNumerator += rateWeight * (block.timestamp - lastAccrual);
        lastAccrual = block.timestamp;
    }

    /// @dev Rounded up like each loan's own interest, so NAV never exceeds what settlement collects.
    function _accruedInterest() private view returns (uint256) {
        return Math.ceilDiv(interestNumerator + rateWeight * (block.timestamp - lastAccrual), INTEREST_DENOMINATOR);
    }

    function _loanInterestNumerator(Loan storage l) private view returns (uint256) {
        return l.principal * l.aprBps * (block.timestamp - l.startedAt);
    }

    function _removeActive(Loan storage l) private {
        activePrincipal -= l.principal;
        interestNumerator -= _loanInterestNumerator(l);
        rateWeight -= l.principal * l.aprBps;
    }

    /// @dev Drops an auction from the book at its current phase. The caller sets the state afterwards.
    function _removeAuction(Loan storage l) private {
        _syncAuctions();
        uint256 debt = l.auctionDebt;
        uint256 elapsed = block.timestamp - l.auctionStartedAt;
        if (elapsed <= PAR_WINDOW) {
            parDebt -= debt;
        } else if (elapsed < AUCTION_DURATION) {
            descentDebt -= debt;
            descentWeight -= debt * l.auctionStartedAt;
        } else if (elapsed < AUCTION_DURATION + WRITE_OFF_DELAY) {
            decayDebt -= debt;
            decayWeight -= debt * l.auctionStartedAt;
        }
        frozenDebt -= debt;
    }

    function _syncAuctions() private {
        Book memory b = _projectBook(block.timestamp);
        parHead = b.parHead;
        descentHead = b.descentHead;
        decayHead = b.decayHead;
        parDebt = b.parDebt;
        descentDebt = b.descentDebt;
        descentWeight = b.descentWeight;
        decayDebt = b.decayDebt;
        decayWeight = b.decayWeight;
    }

    /// @dev Advances each head over the entries whose phase ended by `t`. Closed entries are skipped: they were
    /// removed from the aggregates at the phase they were in when they closed, after a sync at that time.
    function _projectBook(uint256 t) private view returns (Book memory b) {
        b = Book(parHead, descentHead, decayHead, parDebt, descentDebt, descentWeight, decayDebt, decayWeight);
        uint256 length = auctionQueue.length;
        while (b.parHead < length) {
            Loan storage l = loans[auctionQueue[b.parHead]];
            if (t - l.auctionStartedAt <= PAR_WINDOW) break;
            if (l.state == State.Auction) {
                b.parDebt -= l.auctionDebt;
                b.descentDebt += l.auctionDebt;
                b.descentWeight += l.auctionDebt * l.auctionStartedAt;
            }
            ++b.parHead;
        }
        while (b.descentHead < length) {
            Loan storage l = loans[auctionQueue[b.descentHead]];
            if (t - l.auctionStartedAt < AUCTION_DURATION) break;
            if (l.state == State.Auction) {
                b.descentDebt -= l.auctionDebt;
                b.descentWeight -= l.auctionDebt * l.auctionStartedAt;
                b.decayDebt += l.auctionDebt;
                b.decayWeight += l.auctionDebt * l.auctionStartedAt;
            }
            ++b.descentHead;
        }
        while (b.decayHead < length) {
            Loan storage l = loans[auctionQueue[b.decayHead]];
            if (t - l.auctionStartedAt < AUCTION_DURATION + WRITE_OFF_DELAY) break;
            if (l.state == State.Auction) {
                b.decayDebt -= l.auctionDebt;
                b.decayWeight -= l.auctionDebt * l.auctionStartedAt;
            }
            ++b.decayHead;
        }
    }

    /// @dev Sum of the per-loan marks over open auctions at `t`, each phase rounded up once, so the total is within
    /// one base unit per descending or decaying auction of the sum of `auctionMark` values.
    function _auctionMark(Book memory b, uint256 t) private pure returns (uint256 mark) {
        mark = b.parDebt;
        if (b.descentDebt != 0) {
            uint256 elapsedWeight = t * b.descentDebt - b.descentWeight;
            uint256 numerator = AUCTION_START_BPS * AUCTION_DURATION * b.descentDebt
                - (AUCTION_START_BPS - AUCTION_FLOOR_BPS) * elapsedWeight;
            mark += Math.ceilDiv(numerator, BPS * AUCTION_DURATION);
        }
        if (b.decayDebt != 0) {
            // Sum of debt * (start + AUCTION_DURATION + WRITE_OFF_DELAY - t) / (2 * WRITE_OFF_DELAY).
            uint256 remainingWeight =
                b.decayWeight + (AUCTION_DURATION + WRITE_OFF_DELAY) * b.decayDebt - t * b.decayDebt;
            mark += Math.ceilDiv(remainingWeight, 2 * WRITE_OFF_DELAY);
        }
    }
}
