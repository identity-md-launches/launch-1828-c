// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardOracle} from "src/CardOracle.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {Admin} from "src/Admin.sol";
import {MockIntake} from "./helpers/Mocks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TaxedPaymentToken is ERC20 {
    constructor(address holder) ERC20("Taxed payment test", "TAX") {
        _mint(holder, 10 ether);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

contract ZeroRequestIdIntake is IIntake {
    function priceOf(bytes32, address) external pure returns (uint256) {
        return 0.5 ether;
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        return bytes32(0);
    }
}

contract Rejecting1271Signer {
    bool private immutable shouldRevert;

    constructor(bool revert_) {
        shouldRevert = revert_;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        require(!shouldRevert, "registry unavailable");
        return 0xffffffff;
    }
}

contract CardOracleAdversarialTest is Fixture {
    function test_allFifteenAttestationFieldsAreAuthenticated() public {
        bytes32 id = ask();
        for (uint256 field; field < 15; ++field) {
            OracleAttestation.Attestation memory a = attestation(1000);
            bytes memory signature = sign(a);
            if (field == 0) a.requestId = bytes32(uint256(a.requestId) ^ 1);
            else if (field == 1) ++a.chainId;
            else if (field == 2) a.questionHash = bytes32(uint256(a.questionHash) ^ 1);
            else if (field == 3) a.answerType = 4;
            else if (field == 4) a.answer = abi.encode(uint256(1001));
            else if (field == 5) ++a.figure;
            else if (field == 6) ++a.fromBlock;
            else if (field == 7) ++a.toBlock;
            else if (field == 8) a.blockHash = bytes32(uint256(a.blockHash) ^ 1);
            else if (field == 9) a.panelJobId = bytes32(uint256(a.panelJobId) ^ 1);
            else if (field == 10) ++a.panelSize;
            else if (field == 11) ++a.quorum;
            else if (field == 12) ++a.agreed;
            else if (field == 13) --a.issuedAt;
            else ++a.expiresAt;
            vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
            _callback(id, a, signature);
            assertFalse(oracle.consumed(a.requestId));
            assertTrue(oracle.request(id).pending);
        }
        OracleAttestation.Attestation memory good = attestation(1000);
        _callback(id, good, sign(good));
        assertEq(oracle.freshPrice(cardClass).price, 1000e6);
    }

    function test_chainDomainChangeInvalidatesAnOtherwiseValidSignature() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory signature = sign(a);
        vm.chainId(1);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, signature);
        assertTrue(oracle.request(id).pending);
        vm.chainId(11155111);
        _callback(id, a, signature);
    }

    function test_malformedAndHighSSignaturesCannotConsumePendingRequest() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, oracle.attestationDigest(a));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, highS);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, hex"00");
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, abi.encodePacked(r, s, uint8(0)));
        assertTrue(oracle.request(id).pending);
        assertFalse(oracle.consumed(a.requestId));
        _callback(id, a, abi.encodePacked(r, s, v));
    }

    function test_signerRotationImmediatelyRevokesOldSignerWithoutConsumingRequest() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory oldSignature = sign(a);
        uint256 replacementKey = 0xB0B51;
        oracle.setSigner(vm.addr(replacementKey));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, oldSignature);
        assertTrue(oracle.request(id).pending);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(replacementKey, oracle.attestationDigest(a));
        _callback(id, a, abi.encodePacked(r, s, v));
        assertTrue(oracle.consumed(a.requestId));
    }

    function test_1271RejectionAndRevertDoNotSettleRequest() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory signature = sign(a);
        for (uint256 i; i < 2; ++i) {
            oracle.setSigner(address(new Rejecting1271Signer(i == 1)));
            vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
            _callback(id, a, signature);
            assertTrue(oracle.request(id).pending);
            assertFalse(oracle.consumed(a.requestId));
        }
        oracle.setSigner(vm.addr(SIGNER_KEY));
        _callback(id, a, signature);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_signedButInvalidFieldsCannotPublish(uint8 fieldSeed) public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        uint256 field = bound(fieldSeed, 0, 8);
        if (field == 0) a.requestId = bytes32(0);
        else if (field == 1) a.questionHash = bytes32(0);
        else if (field == 2) a.fromBlock = a.toBlock + 1;
        else if (field == 3) --a.issuedAt;
        else if (field == 4) ++a.issuedAt;
        else if (field == 5) ++a.expiresAt;
        else if (field == 6) a.answer = abi.encode(uint256(1000), uint256(0));
        else if (field == 7) a.chainId = 11155111; // Observation chain is 1, consumer chain is Sepolia.
        else a.answer = abi.encode(uint256(1_000_000_000_001));
        bytes memory signature = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, signature);
        assertTrue(oracle.request(id).pending);
        assertEq(oracle.pendingForClass(cardClass), id);
        assertFalse(oracle.consumed(a.requestId));
        (uint256 price, uint64 issued,) = oracle.prices(cardClass);
        assertEq(price, 0);
        assertEq(issued, 0);
    }

    function test_callbackAndRelayCanSettleAtExactRequestDeadline() public {
        bytes32 id = ask();
        vm.warp(oracle.request(id).deadline);
        OracleAttestation.Attestation memory a = attestation(1000);
        _callback(id, a, sign(a));
        assertEq(oracle.freshPrice(cardClass).price, 1000e6);
        bytes32 next = ask();
        vm.warp(oracle.request(next).deadline);
        a = attestation(1001);
        oracle.bindRelay(next, a.requestId, a.questionHash);
        bytes memory signature = sign(a);
        vm.prank(bob);
        oracle.submit(a, signature);
        assertEq(oracle.freshPrice(cardClass).price, 1001e6);
    }

    function test_relayBindingRejectsEmptyIdsConsumedUUIDAndExpiredRequest() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        oracle.bindRelay(id, 0, a.questionHash);
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        oracle.bindRelay(id, a.requestId, 0);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        oracle.bindRelay(bytes32("unknown"), a.requestId, a.questionHash);
        _callback(id, a, sign(a));
        id = ask();
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        oracle.bindRelay(id, a.requestId, a.questionHash);
        vm.warp(oracle.request(id).deadline + 1);
        vm.expectRevert(CardOracle.RequestExpired.selector);
        oracle.bindRelay(id, keccak256("new uuid"), a.questionHash);
    }

    function test_globalUUIDReplayCannotPriceAnotherClass() public {
        bytes32 firstId = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory signature = sign(a);
        _callback(firstId, a, signature);
        bytes32 otherClass = keccak256("different class");
        oracle.setClass(otherClass, cardTemplate(), true);
        vm.prank(bob);
        bytes32 secondId = oracle.requestPrice(otherClass);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        _callback(secondId, a, signature);
        assertTrue(oracle.request(secondId).pending);
        (uint256 price, uint64 issued,) = oracle.prices(otherClass);
        assertEq(price, 0);
        assertEq(issued, 0);
    }

    function test_sameUUIDCannotBeBoundToTwoOpenClasses() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        oracle.bindRelay(id, a.requestId, a.questionHash);
        bytes32 otherClass = keccak256("second class");
        oracle.setClass(otherClass, cardTemplate(), true);
        vm.prank(bob);
        bytes32 otherId = oracle.requestPrice(otherClass);
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        oracle.bindRelay(otherId, a.requestId, a.questionHash);
        assertEq(oracle.intakeForOracleId(a.requestId), id);
        assertTrue(oracle.request(otherId).pending);
    }

    function test_oldFailureOrSuccessCannotClearReplacementPendingRequest() public {
        bytes32 oldId = ask();
        vm.warp(oracle.request(oldId).deadline + 1);
        oracle.clearExpired(oldId);
        bytes32 replacement = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory signature = sign(a);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        _callback(oldId, a, signature);
        assertFalse(intake.fail(oldId, 1, bytes32("body_invalid")));
        assertEq(oracle.pendingForClass(cardClass), replacement);
        assertTrue(oracle.request(replacement).pending);
        _callback(replacement, a, signature);
    }

    function test_invalidFailureStatusIsAtomicAndFailureAllowsImmediateRetry() public {
        bytes32 id = ask();
        uint8[3] memory statuses = [uint8(0), uint8(3), uint8(255)];
        for (uint256 i; i < statuses.length; ++i) {
            vm.expectRevert(CardOracle.BadAttestation.selector);
            vm.prank(address(intake));
            oracle.onFailure(id, statuses[i], bytes32("ignored"), 65535, 65535, hex"abcdef");
            assertTrue(oracle.request(id).pending);
        }
        uint256 cash = imd.balanceOf(alice);
        vm.prank(address(intake));
        oracle.onFailure(id, 1, bytes32("body_invalid"), 65535, 0, hex"abcdef");
        assertEq(imd.balanceOf(alice), cash, "unsigned failure cannot refund or move funds");
        bytes32 next = ask();
        assertTrue(next != id);
        assertEq(oracle.pendingForClass(cardClass), next);
    }

    function test_feeOnTransferPaymentRejectedWithoutBurnOrPendingState() public {
        TaxedPaymentToken token = new TaxedPaymentToken(alice);
        oracle.setPayment(address(token), 0.5 ether);
        vm.prank(alice);
        token.approve(address(oracle), 0.5 ether);
        vm.expectRevert(CardOracle.WrongPayment.selector);
        ask();
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.totalSupply(), 10 ether, "tax burn reverted atomically");
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(oracle.pendingForClass(cardClass), 0);
        assertEq(intake.nonce(), 0);
    }

    function test_missingAllowanceAndInsufficientBalanceDoNotOpenRequests() public {
        vm.prank(alice);
        imd.approve(address(oracle), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(oracle), 0, 0.5 ether)
        );
        ask();
        vm.startPrank(alice);
        imd.approve(address(oracle), 0.5 ether);
        imd.transfer(bob, 100 ether);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 0.5 ether));
        ask();
        assertEq(oracle.pendingForClass(cardClass), 0);
        assertEq(intake.nonce(), 0);
    }

    function test_zeroAndDuplicateIntakeIDsRevertTheFeeTransfer() public {
        ZeroRequestIdIntake zeroId = new ZeroRequestIdIntake();
        uint256 cash = imd.balanceOf(alice);
        oracle.setIntake(address(zeroId));
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        ask();
        assertEq(imd.balanceOf(alice), cash);
        assertEq(imd.balanceOf(address(zeroId)), 0);
        assertEq(imd.allowance(address(oracle), address(zeroId)), 0);
        oracle.setIntake(address(intake));
        bytes32 oldId = ask();
        assertTrue(intake.fail(oldId, 2, bytes32("disagreed")));
        intake.setForcedId(oldId);
        cash = imd.balanceOf(alice);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        ask();
        assertEq(imd.balanceOf(alice), cash);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(oracle.pendingForClass(cardClass), 0);
        assertFalse(oracle.request(oldId).pending);
    }

    function test_allOracleAdminMutationsRejectAnUnprivilegedCaller() public {
        bytes[] memory operations = new bytes[](8);
        operations[0] = abi.encodeCall(oracle.setClass, (cardClass, cardTemplate(), false));
        operations[1] = abi.encodeCall(oracle.setObservationChain, (11155111));
        operations[2] = abi.encodeCall(oracle.setIntake, (bob));
        operations[3] = abi.encodeCall(oracle.setPayment, (address(imd), 1 ether));
        operations[4] = abi.encodeCall(oracle.setAction, (bytes32("oracle.request@oracle-2")));
        operations[5] = abi.encodeCall(oracle.setSigner, (bob));
        operations[6] = abi.encodeCall(oracle.setPanel, (uint16(5), uint16(2)));
        operations[7] = abi.encodeCall(oracle.setGuardian, (bob));
        bytes memory expected = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob);
        for (uint256 i; i < operations.length; ++i) {
            vm.prank(bob);
            (bool ok, bytes memory reason) = address(oracle).call(operations[i]);
            assertFalse(ok, "admin selector must reject bob");
            assertEq(reason, expected);
        }
        assertTrue(oracle.allowed(cardClass));
        assertEq(oracle.oracleSigner(), vm.addr(SIGNER_KEY));
    }

    function test_invalidConfigurationAndMinimumPanelBoundaries() public {
        vm.expectRevert(Admin.InvalidAddress.selector);
        oracle.setIntake(address(0));
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setPayment(address(0), 0.5 ether);
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setPanel(4, 2);
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setPanel(5, 1);
        oracle.setPanel(5, 2);
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1);
        a.panelSize = 5;
        a.quorum = 2;
        a.agreed = 2;
        _callback(id, a, sign(a));
        assertEq(oracle.freshPrice(cardClass).price, 1e6);
    }
}
