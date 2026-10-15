// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "src/MockUSDC.sol";
import {MockCardNFT} from "src/MockCardNFT.sol";
import {CardPool} from "src/CardPool.sol";
import {CardOracle} from "src/CardOracle.sol";
import {CardLending} from "src/CardLending.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {TestIMD, MockIntake} from "../helpers/Mocks.sol";

/// @dev Closed universe of four actors and twelve cards. Ghosts record cash flows,
/// not values copied back from the protocol's accounting variables.
contract CardVaultHandler is Test {
    uint256 internal constant SIGNER_KEY = 0xCA4D;
    uint256 internal constant DENOMINATOR = 10_000 * 365 days;
    MockUSDC public usdc;
    MockCardNFT public nft;
    CardPool public pool;
    CardOracle public oracle;
    CardLending public lending;
    TestIMD public imd;
    MockIntake public intake;
    address[4] public actors;
    bytes32 public cardClass;
    mapping(uint256 => address) public expectedHolder;
    mapping(uint256 => bool) public closed;
    mapping(address => uint256) public expectedSurplus;
    mapping(bytes4 => uint256) public calls;
    uint256 public cashIn;
    uint256 public cashOut;
    uint256 public reserveAdded;
    uint256 public reserveSpent;
    uint256 public supply;
    uint256 public nonce;

    constructor() {
        usdc = new MockUSDC(address(this));
        nft = new MockCardNFT(address(this));
        pool = new CardPool(address(this), usdc);
        imd = new TestIMD();
        intake = new MockIntake();
        oracle = new CardOracle(address(this), address(intake), address(imd), vm.addr(SIGNER_KEY));
        lending = new CardLending(address(this), nft, pool, oracle, usdc);
        pool.setLending(address(lending));
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("vault actor ", vm.toString(i)));
            actors[i] = actor;
            usdc.mint(actor, 1_000_000e6);
            vm.startPrank(actor);
            usdc.approve(address(pool), type(uint256).max);
            usdc.approve(address(lending), type(uint256).max);
            nft.setApprovalForAll(address(lending), true);
            vm.stopPrank();
            for (uint256 j; j < 3; ++j) {
                MockCardNFT.Card memory card = MockCardNFT.Card(
                    "Pokemon", "Pokemon Base Set", "Charizard", "4", "PSA", "10", vm.toString(i * 3 + j)
                );
                uint256 token = nft.mint(actor, card);
                expectedHolder[token] = actor;
                cardClass = nft.computeClassId(card);
            }
        }
        supply = 5_000_000e6;
        oracle.setClass(
            cardClass,
            CardOracle.Template("Charizard", "4", "Pokemon Base Set", "pokemon-base-set", "charizard-4", "PSA 10"),
            true
        );
        imd.mint(address(this), 1_000 ether);
        imd.approve(address(oracle), type(uint256).max);
        vm.prank(actors[0]);
        pool.deposit(100_000e6, actors[0]);
        cashIn = 100_000e6;
    }

    function deposit(uint256 who, uint256 seed, bool byShares) external {
        if (pool.paused()) return;
        address actor = actors[who % 4];
        uint256 balance = usdc.balanceOf(actor);
        if (balance == 0) return;
        uint256 assets = bound(seed, 1, _min(balance, 100_000e6));
        uint256 shares = pool.previewDeposit(assets);
        if (shares == 0) return;
        uint256 beforeShares = pool.balanceOf(actor);
        vm.prank(actor);
        if (byShares) assets = pool.mint(shares, actor);
        else shares = pool.deposit(assets, actor);
        assertEq(pool.balanceOf(actor), beforeShares + shares, "deposit recipient shares");
        assertEq(usdc.balanceOf(actor), balance - assets, "deposit payer cash");
        cashIn += assets;
        ++calls[this.deposit.selector];
    }

    function withdraw(uint256 who, uint256 seed, bool byShares) external {
        address actor = actors[who % 4];
        uint256 balance = usdc.balanceOf(actor);
        uint256 beforeShares = pool.balanceOf(actor);
        uint256 assets;
        uint256 shares;
        if (byShares) {
            uint256 maximum = pool.maxRedeem(actor);
            if (maximum == 0) return;
            shares = bound(seed, 1, maximum);
            if (pool.previewRedeem(shares) == 0) return;
            vm.prank(actor);
            assets = pool.redeem(shares, actor, actor);
        } else {
            uint256 maximum = pool.maxWithdraw(actor);
            if (maximum == 0) return;
            assets = bound(seed, 1, maximum);
            vm.prank(actor);
            shares = pool.withdraw(assets, actor, actor);
        }
        assertEq(usdc.balanceOf(actor), balance + assets, "withdraw receiver cash");
        assertEq(pool.balanceOf(actor), beforeShares - shares, "withdraw burns shares");
        cashOut += assets;
        ++calls[this.withdraw.selector];
    }

    function donate(uint256 who, uint256 seed, bool toReserve) external {
        address actor = actors[who % 4];
        uint256 balance = usdc.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(seed, 1, _min(balance, 1000e6));
        uint256 shares = pool.totalSupply();
        uint256 nav = pool.totalAssets();
        vm.prank(actor);
        if (toReserve) pool.fundReserve(amount);
        else usdc.transfer(address(pool), amount);
        cashIn += amount;
        if (toReserve) reserveAdded += amount;
        assertEq(pool.totalSupply(), shares, "donations cannot mint shares");
        assertEq(pool.totalAssets(), nav + (toReserve ? 0 : amount), "reserve excluded from NAV");
        ++calls[this.donate.selector];
    }

    function transfer(uint256 who, uint256 to, uint256 seed, bool shares) external {
        address actor = actors[who % 4];
        address receiver = actors[to % 4];
        uint256 amount = bound(seed, 0, shares ? pool.balanceOf(actor) : usdc.balanceOf(actor));
        vm.prank(actor);
        if (shares) pool.transfer(receiver, amount);
        else usdc.transfer(receiver, amount);
        ++calls[this.transfer.selector];
    }

    function borrow(uint256 tokenSeed, uint256 amountSeed) external {
        if (lending.paused() || pool.paused()) return;
        uint256 token = bound(tokenSeed, 1, 12);
        address actor = expectedHolder[token];
        if (actor == address(lending) || pool.availableLiquidity() < 2) return;
        (uint256 price,, uint64 expiry) = oracle.prices(cardClass);
        if (price == 0 || vm.getBlockTimestamp() > expiry) {
            _publish(1000);
            price = 1000e6;
        }
        uint256 maximum = _min(price * 45 / 100, pool.availableLiquidity());
        if (maximum < 2) return;
        uint256 amount = bound(amountSeed, 2, maximum);
        uint256 beforeCash = usdc.balanceOf(actor);
        uint256 beforeNav = pool.totalAssets();
        uint256 id = lending.nextLoanId();
        vm.prank(actor);
        assertEq(lending.borrow(token, amount), id, "monotonic loan ID");
        uint256 fee = (amount + 99) / 100;
        cashOut += amount - fee;
        reserveAdded += fee;
        expectedHolder[token] = address(lending);
        CardLending.Loan memory l = lending.loan(id);
        assertEq(l.principal, amount, "gross debt equals borrowed principal");
        assertEq(l.borrower, actor, "borrower recorded");
        assertEq(l.maturity, vm.getBlockTimestamp() + 30 days, "term");
        assertEq(usdc.balanceOf(actor), beforeCash + amount - fee, "borrow pays net amount");
        assertEq(pool.totalAssets(), beforeNav, "draw preserves NAV");
        ++calls[this.borrow.selector];
    }

    function repay(uint256 idSeed, uint256 who) external {
        uint256 id = _id(idSeed);
        CardLending.Loan memory l = lending.loan(id);
        if (l.state != CardLending.State.Active && l.state != CardLending.State.Auction) return;
        address payer = actors[who % 4];
        uint256 debt = lending.debtOf(id);
        if (usdc.balanceOf(payer) < debt) return;
        uint256 beforeCash = usdc.balanceOf(payer);
        vm.prank(payer);
        lending.repay(id);
        cashIn += debt;
        expectedHolder[l.tokenId] = l.borrower;
        closed[id] = true;
        assertEq(usdc.balanceOf(payer), beforeCash - debt, "repayment cash");
        assertEq(lending.debtOf(id), 0, "repayment clears debt");
        assertEq(nft.ownerOf(l.tokenId), l.borrower, "third party cannot take collateral");
        ++calls[this.repay.selector];
    }

    function extend(uint256 idSeed) external {
        if (lending.paused()) return;
        uint256 id = _id(idSeed);
        CardLending.Loan memory l = lending.loan(id);
        if (l.state != CardLending.State.Active || vm.getBlockTimestamp() + 1 >= l.maturity) return;
        _publish(100_000);
        uint256 interest = lending.interestOf(id);
        if (l.principal + interest > 45_000e6) {
            vm.expectRevert(CardLending.TooMuchDebt.selector);
            vm.prank(l.borrower);
            lending.extend(id);
            return;
        }
        if (usdc.balanceOf(l.borrower) < interest) return;
        uint256 beforeReserve = pool.reserve();
        vm.prank(l.borrower);
        lending.extend(id);
        cashIn += interest;
        CardLending.Loan memory renewed = lending.loan(id);
        assertEq(renewed.principal, l.principal, "extension cannot compound principal");
        assertEq(renewed.aprBps, lending.aprBps(), "extension snapshots new APR");
        assertEq(lending.debtOf(id), l.principal, "interest settled on extension");
        assertEq(pool.reserve(), beforeReserve, "no second origination fee");
        assertEq(renewed.maturity, vm.getBlockTimestamp() + 30 days, "renewed term");
        ++calls[this.extend.selector];
    }

    function liquidate(uint256 idSeed, bool byPrice) external {
        if (lending.paused()) return;
        uint256 id = _id(idSeed);
        CardLending.Loan memory l = lending.loan(id);
        if (l.state != CardLending.State.Active) return;
        if (byPrice) _publish(0);
        else if (vm.getBlockTimestamp() < l.maturity) vm.warp(l.maturity);
        uint256 debt = lending.debtOf(id);
        lending.liquidate(id);
        assertEq(lending.debtOf(id), debt, "auction freezes debt");
        assertEq(nft.ownerOf(l.tokenId), address(lending), "auction keeps custody");
        ++calls[this.liquidate.selector];
    }

    function buy(uint256 idSeed, uint256 who, uint256 to) external {
        uint256 id = _id(idSeed);
        CardLending.Loan memory l = lending.loan(id);
        if (l.state != CardLending.State.Auction) return;
        address payer = actors[who % 4];
        address receiver = actors[to % 4];
        uint256 price = lending.auctionPrice(id);
        if (usdc.balanceOf(payer) < price) return;
        uint256 debt = l.auctionDebt;
        uint256 poolPayment = _min(price, debt);
        uint256 cover = _min(reserveAdded - reserveSpent, debt - poolPayment);
        uint256 beforeCash = usdc.balanceOf(payer);
        vm.prank(payer);
        lending.buy(id, price, receiver);
        cashIn += poolPayment;
        reserveSpent += cover;
        expectedSurplus[l.borrower] += price - poolPayment;
        expectedHolder[l.tokenId] = receiver;
        closed[id] = true;
        assertEq(usdc.balanceOf(payer), beforeCash - price, "auction buyer pays quote");
        assertEq(lending.debtOf(id), 0, "sale retires entire receivable");
        assertEq(nft.ownerOf(l.tokenId), receiver, "auction receiver owns card");
        ++calls[this.buy.selector];
    }

    function claim(uint256 who, uint256 to) external {
        address actor = actors[who % 4];
        address receiver = actors[to % 4];
        uint256 amount = expectedSurplus[actor];
        if (amount == 0) return;
        uint256 beforeCash = usdc.balanceOf(receiver);
        vm.prank(actor);
        lending.claimSurplus(receiver);
        expectedSurplus[actor] = 0;
        assertEq(usdc.balanceOf(receiver), beforeCash + amount, "surplus paid exactly once");
        ++calls[this.claim.selector];
    }

    function elapse(uint256 seed) external {
        uint256 delta = bound(seed, 1, 40 days);
        uint256 debt = lending.totalDebt();
        vm.warp(vm.getBlockTimestamp() + delta);
        assertGe(lending.totalDebt(), debt, "time cannot decrease outstanding debt");
        ++calls[this.elapse.selector];
    }

    function admin(uint256 rateSeed, bool pausePool, bool pauseLending) external {
        lending.setAPR(uint16(bound(rateSeed, 0, 10_000)));
        if (pool.paused() != pausePool) {
            if (pausePool) pool.pause();
            else pool.unpause();
        }
        if (lending.paused() != pauseLending) {
            if (pauseLending) lending.pause();
            else lending.unpause();
        }
        ++calls[this.admin.selector];
    }

    function roundTrip(uint256 who, uint256 seed, bool byShares) external {
        if (pool.paused()) return;
        address actor = actors[who % 4];
        uint256 beforeCash = usdc.balanceOf(actor);
        if (beforeCash == 0) return;
        uint256 amount = bound(seed, 1, _min(beforeCash, 1000e6));
        uint256 shares = pool.previewDeposit(amount);
        if (shares == 0) return;
        uint256 oldShares = pool.balanceOf(actor);
        vm.startPrank(actor);
        if (byShares) amount = pool.mint(shares, actor);
        else shares = pool.deposit(amount, actor);
        cashIn += amount;
        if (pool.previewRedeem(shares) != 0) cashOut += pool.redeem(shares, actor, actor);
        vm.stopPrank();
        // If the received shares are dust they remain owned, but cannot hide a cash profit.
        assertLe(usdc.balanceOf(actor), beforeCash, "round trip creates no cash");
        assertGe(pool.balanceOf(actor), oldShares, "round trip cannot spend prior shares");
        ++calls[this.roundTrip.selector];
    }

    function checkAccounting() external view {
        assertEq(usdc.balanceOf(address(pool)), cashIn - cashOut, "pool cash conservation");
        assertEq(pool.reserve(), reserveAdded - reserveSpent, "reserve flow conservation");
        assertGe(usdc.balanceOf(address(pool)), pool.reserve(), "reserve always cash backed");
        uint256 tokenBalances =
            usdc.balanceOf(address(this)) + usdc.balanceOf(address(pool)) + usdc.balanceOf(address(lending));
        uint256 shares;
        uint256 surplusTotal;
        for (uint256 i; i < 4; ++i) {
            tokenBalances += usdc.balanceOf(actors[i]);
            shares += pool.balanceOf(actors[i]);
            surplusTotal += expectedSurplus[actors[i]];
            assertEq(lending.surplus(actors[i]), expectedSurplus[actors[i]], "borrower surplus ledger");
        }
        assertEq(tokenBalances, supply, "USDC cannot disappear or be created by protocol");
        assertEq(usdc.totalSupply(), supply, "no unauthorized mint");
        assertEq(pool.totalSupply(), shares, "all pool shares belong to tracked lenders");
        assertEq(lending.totalSurplus(), surplusTotal, "surplus aggregate");
        assertEq(usdc.balanceOf(address(lending)), surplusTotal, "surplus cash backing");
        assertEq(usdc.allowance(address(lending), address(pool)), 0, "settlement leaves no allowance");

        uint256 principal;
        uint256 frozen;
        uint256 weight;
        uint256 interest;
        uint256 individualDebts;
        uint256 activeCount;
        uint256 custodyCount;
        uint256 next = lending.nextLoanId();
        for (uint256 id = 1; id < next; ++id) {
            CardLending.Loan memory l = lending.loan(id);
            if (closed[id]) assertEq(uint256(l.state), uint256(CardLending.State.Closed), "closed never reopens");
            if (l.state == CardLending.State.Active) {
                principal += l.principal;
                weight += l.principal * l.aprBps;
                interest += l.principal * l.aprBps * (vm.getBlockTimestamp() - l.startedAt);
                ++activeCount;
            } else if (l.state == CardLending.State.Auction) {
                frozen += l.auctionDebt;
                assertEq(lending.interestOf(id), 0, "auction accrues no interest");
                assertEq(lending.debtOf(id), l.auctionDebt, "auction debt fixed");
            } else {
                assertTrue(closed[id], "loan cannot silently close");
                assertEq(lending.debtOf(id), 0, "closed debt is zero");
            }
            individualDebts += lending.debtOf(id);
            if (l.state == CardLending.State.Active || l.state == CardLending.State.Auction) {
                ++custodyCount;
                assertEq(lending.collateralLoan(l.tokenId), id, "unique active collateral mapping");
                assertEq(nft.ownerOf(l.tokenId), address(lending), "outstanding debt has custody");
            }
        }
        assertEq(lending.activePrincipal(), principal, "principal sum");
        assertEq(lending.frozenDebt(), frozen, "auction debt sum");
        assertEq(lending.rateWeight(), weight, "APR weight sum");
        assertEq(lending.totalDebt(), principal + frozen + interest / DENOMINATOR, "aggregate debt matches loans");
        assertGe(lending.totalDebt(), individualDebts, "rounding cannot undercount loan debt");
        assertLe(lending.totalDebt() - individualDebts, activeCount == 0 ? 0 : activeCount - 1, "fractional debt bound");
        assertEq(pool.totalAssets(), cashIn - cashOut - pool.reserve() + lending.totalDebt(), "NAV backing");
        assertEq(nft.balanceOf(address(lending)), custodyCount, "no unrecorded collateral");
        for (uint256 token = 1; token <= 12; ++token) {
            assertEq(nft.ownerOf(token), expectedHolder[token], "NFT follows authorized state transitions");
            if (expectedHolder[token] != address(lending)) assertEq(lending.collateralLoan(token), 0, "released lien");
        }
    }

    /// @dev Called after each fuzz sequence, never selected as a random action.
    /// A solvent payer must be able to close every loan even while paused, then
    /// all surplus claims and every advertised cash exit must remain executable.
    function closeAllAndExit() external {
        usdc.approve(address(lending), type(uint256).max);
        for (uint256 id = 1; id < lending.nextLoanId(); ++id) {
            CardLending.Loan memory l = lending.loan(id);
            if (l.state != CardLending.State.Active && l.state != CardLending.State.Auction) continue;
            uint256 debt = lending.debtOf(id);
            uint256 balance = usdc.balanceOf(address(this));
            if (balance < debt) {
                usdc.mint(address(this), debt - balance);
                supply += debt - balance;
            }
            lending.repay(id);
            cashIn += debt;
            expectedHolder[l.tokenId] = l.borrower;
            closed[id] = true;
        }
        for (uint256 i; i < 4; ++i) {
            this.claim(i, i);
            uint256 maximum = pool.maxWithdraw(actors[i]);
            if (maximum != 0) {
                vm.prank(actors[i]);
                pool.withdraw(maximum, actors[i], actors[i]);
                cashOut += maximum;
            }
        }
        assertEq(lending.totalDebt(), 0, "all positions can be repaid");
        assertEq(lending.interestNumerator(), 0, "no orphaned accrued interest");
        assertEq(lending.rateWeight(), 0, "no orphaned APR weight");
        assertEq(lending.totalSurplus(), 0, "all surplus can be claimed");
        assertEq(nft.balanceOf(address(lending)), 0, "all collateral released");
        this.checkAccounting();
    }

    function _id(uint256 seed) internal view returns (uint256) {
        uint256 next = lending.nextLoanId();
        return next == 1 ? 0 : 1 + seed % (next - 1);
    }

    function _publish(uint256 dollars) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes32 id = oracle.requestPrice(cardClass);
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("vault invariant quote", ++nonce));
        a.chainId = 1;
        a.questionHash = keccak256("Charizard PSA 10 quote");
        a.answerType = 3;
        a.answer = abi.encode(dollars);
        a.figure = dollars;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("closing block");
        a.panelJobId = keccak256(abi.encode(nonce));
        a.panelSize = 30;
        a.quorum = 21;
        a.agreed = 25;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, oracle.attestationDigest(a));
        (bool ok,) = intake.deliver(id, a, abi.encodePacked(r, s, v));
        assertTrue(ok, "valid oracle update must fit callback gas stipend");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
