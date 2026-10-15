// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CardOracle} from "src/CardOracle.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {TestIMD, MockIntake} from "../helpers/Mocks.sol";

contract OracleLifecycleHandler is Test {
    enum Outcome {
        Pending,
        Success,
        Failure,
        Timeout
    }

    struct Opened {
        bytes32 intakeId;
        bytes32 uuid;
        uint256 classIndex;
        MockIntake source;
        Outcome outcome;
        bool bound;
    }

    uint256 private constant KEY = 0x0A4C1E;
    CardOracle public oracle;
    TestIMD public imd;
    MockIntake[2] public intakes;
    address[3] public payers;
    bytes32[3] public classes;
    bool[3] public enabled;
    bytes32[3] public pending;
    CardOracle.Price[3] private expectedPrices;
    Opened[] private opened;
    mapping(bytes32 => uint256) private indexPlusOne;
    mapping(address => uint256) public feesReceived;
    mapping(address => uint256) public feesPaid;
    mapping(bytes4 => uint256) public calls;
    uint256 public donations;
    uint256 public nonce;

    constructor() {
        imd = new TestIMD();
        intakes[0] = new MockIntake();
        intakes[1] = new MockIntake();
        oracle = new CardOracle(address(this), address(intakes[0]), address(imd), vm.addr(KEY));
        for (uint256 i; i < 3; ++i) {
            classes[i] = keccak256(abi.encode("oracle lifecycle class", i));
            enabled[i] = true;
            oracle.setClass(classes[i], _template(), true);
            payers[i] = makeAddr(string.concat("oracle payer ", vm.toString(i)));
            imd.mint(payers[i], 1000 ether);
            vm.prank(payers[i]);
            imd.approve(address(oracle), type(uint256).max);
        }
        imd.mint(address(this), 1000 ether);
    }

    function open(uint256 classSeed, uint256 payerSeed) external {
        uint256 c = classSeed % 3;
        if (!enabled[c] || pending[c] != 0 || oracle.paused()) return;
        address payer = payers[payerSeed % 3];
        MockIntake source = MockIntake(oracle.intake());
        uint256 fee = oracle.requestFee();
        vm.prank(payer);
        bytes32 id = oracle.requestPrice(classes[c]);
        bytes32 uuid = keccak256(abi.encode("separate signed oracle UUID", ++nonce));
        opened.push(Opened(id, uuid, c, source, Outcome.Pending, false));
        indexPlusOne[id] = opened.length;
        pending[c] = id;
        feesReceived[address(source)] += fee;
        feesPaid[payer] += fee;
        assertEq(oracle.request(id).bodyHash, keccak256(source.ask(id).body), "body binding");
        ++calls[this.open.selector];
    }

    function deliver(uint256 classSeed, uint256 priceSeed, bool relay) external {
        uint256 c = classSeed % 3;
        if (pending[c] == 0) return;
        Opened storage r = opened[indexPlusOne[pending[c]] - 1];
        CardOracle.Request memory request = oracle.request(r.intakeId);
        if (vm.getBlockTimestamp() >= request.deadline) return;
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 dollars = bound(priceSeed, 0, 1_000_000_000_000);
        OracleAttestation.Attestation memory a = _answer(r, dollars);
        bytes memory signature = _sign(a);
        if (relay) {
            if (!r.bound) {
                oracle.bindRelay(r.intakeId, r.uuid, a.questionHash);
                r.bound = true;
            }
            vm.prank(payers[2]);
            oracle.submit(a, signature);
        } else {
            (bool ok,) = r.source.deliver(r.intakeId, a, signature);
            assertTrue(ok, "valid callback must complete under 200k gas");
        }
        expectedPrices[c] = CardOracle.Price(dollars * 1e6, a.issuedAt, a.expiresAt);
        r.outcome = Outcome.Success;
        pending[c] = 0;
        ++calls[this.deliver.selector];
    }

    function bind(uint256 classSeed) external {
        uint256 c = classSeed % 3;
        if (pending[c] == 0) return;
        Opened storage r = opened[indexPlusOne[pending[c]] - 1];
        if (r.bound || vm.getBlockTimestamp() > oracle.request(r.intakeId).deadline) return;
        oracle.bindRelay(r.intakeId, r.uuid, _question(r));
        r.bound = true;
        ++calls[this.bind.selector];
    }

    function fail(uint256 classSeed, bool noConsensus) external {
        uint256 c = classSeed % 3;
        if (pending[c] == 0) return;
        Opened storage r = opened[indexPlusOne[pending[c]] - 1];
        assertTrue(r.source.fail(r.intakeId, noConsensus ? 2 : 1, bytes32("body_invalid")), "failure callback");
        r.outcome = Outcome.Failure;
        pending[c] = 0;
        ++calls[this.fail.selector];
    }

    function timeout(uint256 classSeed) external {
        uint256 c = classSeed % 3;
        if (pending[c] == 0) return;
        Opened storage r = opened[indexPlusOne[pending[c]] - 1];
        uint256 deadline = oracle.request(r.intakeId).deadline;
        if (vm.getBlockTimestamp() <= deadline) vm.warp(deadline + 1);
        vm.prank(payers[1]);
        oracle.clearExpired(r.intakeId);
        r.outcome = Outcome.Timeout;
        pending[c] = 0;
        ++calls[this.timeout.selector];
    }

    function rejectWrongSender(uint256 classSeed) external {
        uint256 c = classSeed % 3;
        if (pending[c] == 0) return;
        Opened storage r = opened[indexPlusOne[pending[c]] - 1];
        OracleAttestation.Attestation memory a = _answer(r, 1234);
        bytes memory signature = _sign(a);
        vm.expectRevert(CardOracle.NotIntake.selector);
        vm.prank(payers[0]);
        oracle.onPrice(r.intakeId, a, signature);
        vm.expectRevert(CardOracle.NotIntake.selector);
        vm.prank(payers[0]);
        oracle.onFailure(r.intakeId, 2, bytes32("disagreed"), 0, 0, "");
        ++calls[this.rejectWrongSender.selector];
    }

    function rejectReplay(uint256 seed) external {
        if (opened.length == 0) return;
        Opened storage r = opened[seed % opened.length];
        if (r.outcome == Outcome.Pending) return;
        OracleAttestation.Attestation memory a = _answer(r, 9876);
        bytes memory signature = _sign(a);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        vm.prank(address(r.source));
        oracle.onPrice(r.intakeId, a, signature);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        oracle.submit(a, signature);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        vm.prank(address(r.source));
        oracle.onFailure(r.intakeId, 1, bytes32("body_invalid"), 0, 0, "");
        ++calls[this.rejectReplay.selector];
    }

    function configure(uint256 seed, bool paused) external {
        oracle.setIntake(address(intakes[seed % 2]));
        uint16 size = uint16(bound(seed, 5, 100));
        oracle.setPanel(size, uint16(2 + seed % (size - 1)));
        oracle.setObservationChain(seed % 2 == 0 ? 1 : 11155111);
        if (oracle.paused() != paused) {
            if (paused) oracle.pause();
            else oracle.unpause();
        }
        ++calls[this.configure.selector];
    }

    function catalog(uint256 classSeed, bool allow) external {
        uint256 c = classSeed % 3;
        if (pending[c] != 0) {
            vm.expectRevert(CardOracle.ClassBusy.selector);
            oracle.setClass(classes[c], _template(), allow);
        } else {
            oracle.setClass(classes[c], _template(), allow);
            enabled[c] = allow;
            delete expectedPrices[c];
        }
        ++calls[this.catalog.selector];
    }

    function elapse(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1, 3 days));
        ++calls[this.elapse.selector];
    }

    function donate(uint256 seed) external {
        uint256 available = imd.balanceOf(address(this));
        if (available == 0) return;
        uint256 amount = bound(seed, 1, available);
        imd.transfer(address(oracle), amount);
        donations += amount;
        ++calls[this.donate.selector];
    }

    function checkLifecycle() external view {
        assertEq(imd.balanceOf(address(oracle)), donations, "oracle cannot spend donations as caller fee");
        uint256 allBalances = imd.balanceOf(address(this)) + donations;
        for (uint256 i; i < 2; ++i) {
            assertEq(imd.balanceOf(address(intakes[i])), feesReceived[address(intakes[i])], "exact fees, no refunds");
            assertEq(imd.allowance(address(oracle), address(intakes[i])), 0, "no residual intake approval");
            allBalances += imd.balanceOf(address(intakes[i]));
        }
        for (uint256 i; i < 3; ++i) {
            assertEq(imd.balanceOf(payers[i]), 1000 ether - feesPaid[payers[i]], "only caller funds request");
            allBalances += imd.balanceOf(payers[i]);
            assertEq(oracle.pendingForClass(classes[i]), pending[i], "class pending index");
            assertEq(oracle.allowed(classes[i]), enabled[i], "catalog model");
            (uint256 price, uint64 issued, uint64 expires) = oracle.prices(classes[i]);
            assertEq(price, expectedPrices[i].price, "only successful answer changes price");
            assertEq(issued, expectedPrices[i].issuedAt, "signed issuance preserved");
            assertEq(expires, expectedPrices[i].expiresAt, "signed expiry preserved");
        }
        assertEq(allBalances, 4000 ether, "IMD conservation");
        for (uint256 i; i < opened.length; ++i) {
            Opened storage r = opened[i];
            CardOracle.Request memory actual = oracle.request(r.intakeId);
            assertEq(actual.pending, r.outcome == Outcome.Pending, "terminal requests stay settled");
            assertEq(actual.intake, address(r.source), "intake immutable per request");
            assertEq(actual.classId, classes[r.classIndex], "request class immutable");
            assertEq(oracle.consumed(r.uuid), r.outcome == Outcome.Success, "UUID consumed exactly on success");
            if (r.bound) assertEq(oracle.intakeForOracleId(r.uuid), r.intakeId, "relay binding immutable");
        }
    }

    function _answer(Opened storage r, uint256 dollars) internal view returns (OracleAttestation.Attestation memory a) {
        CardOracle.Request memory request = oracle.request(r.intakeId);
        a.requestId = r.uuid;
        a.chainId = request.observationChainId;
        a.questionHash = _question(r);
        a.answerType = 3;
        a.answer = abi.encode(dollars);
        a.figure = dollars;
        a.fromBlock = 1;
        a.toBlock = 2;
        a.blockHash = keccak256("oracle invariant closing block");
        a.panelJobId = keccak256(abi.encode(r.uuid));
        a.panelSize = request.panelSize;
        a.quorum = request.quorum;
        a.agreed = request.panelSize;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = a.issuedAt + 1 days;
    }

    function _question(Opened storage r) internal view returns (bytes32) {
        return keccak256(abi.encode("resolved question", r.intakeId, r.classIndex));
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, oracle.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _template() internal pure returns (CardOracle.Template memory) {
        return CardOracle.Template("Charizard", "4", "Pokemon Base Set", "pokemon-base-set", "charizard-4", "PSA 10");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CardOracleInvariantTest is Test {
    OracleLifecycleHandler internal handler;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        handler = new OracleLifecycleHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.deliver.selector;
        selectors[2] = handler.bind.selector;
        selectors[3] = handler.fail.selector;
        selectors[4] = handler.timeout.selector;
        selectors[5] = handler.rejectWrongSender.selector;
        selectors[6] = handler.rejectReplay.selector;
        selectors[7] = handler.configure.selector;
        selectors[8] = handler.catalog.selector;
        selectors[9] = handler.elapse.selector;
        selectors[10] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_requestsSettleOnceAndFeesAndPricesMatchOutcomes() public view {
        handler.checkLifecycle();
    }

    function test_handlerExercisesCallbacksRelaysFailureTimeoutAndRotation() public {
        handler.open(0, 0);
        handler.open(1, 1);
        handler.open(2, 2);
        handler.rejectWrongSender(0);
        handler.bind(0);
        handler.configure(99, true);
        handler.deliver(0, 1000, true);
        handler.deliver(1, 0, false);
        handler.fail(2, true);
        handler.rejectReplay(0);
        handler.configure(40, false);
        handler.open(2, 0);
        handler.bind(2);
        handler.timeout(2);
        handler.rejectReplay(3);
        handler.catalog(2, false);
        handler.catalog(2, true);
        handler.open(2, 1);
        handler.deliver(2, 1_000_000_000_000, false);
        handler.elapse(1 days + 1);
        handler.donate(7 ether);
        handler.checkLifecycle();
        assertEq(handler.calls(handler.deliver.selector), 3);
        assertEq(handler.calls(handler.fail.selector), 1);
        assertEq(handler.calls(handler.timeout.selector), 1);
        assertEq(handler.calls(handler.rejectReplay.selector), 2);
    }
}
