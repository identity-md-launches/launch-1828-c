// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {MockIntake, TestIMD} from "./helpers/Mocks.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CardOracleTest is Fixture {
    function test_requestChargesCallerAndBuildsCanonicalBody() public {
        uint256 beforeBalance = imd.balanceOf(alice);
        bytes32 id = ask();
        MockIntake.Ask memory r = intake.ask(id);
        assertEq(imd.balanceOf(alice), beforeBalance - 0.5 ether);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(imd.balanceOf(address(oracle)), 0);
        assertEq(imd.allowance(address(oracle), address(intake)), 0);
        assertEq(r.action, bytes32("oracle.request@oracle-1"));
        assertEq(r.amount, 0.5 ether);
        assertEq(r.asset, address(imd));
        assertEq(r.callback.target, address(oracle));
        assertEq(r.callback.selector, oracle.onPrice.selector);
        assertEq(r.failure, oracle.onFailure.selector);
        assertEq(oracle.pendingForClass(cardClass), id);
        string memory body = string(r.body);
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), 11155111);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(oracle));
        assertEq(vm.parseJsonUint(body, ".toleranceBps"), 500);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86400);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(body, ".quorum"), 21);
        assertEq(vm.parseJsonString(body, ".definitions.unit"), "US dollars.");
        assertEq(
            vm.parseJsonString(body, ".guards.sources[0]"),
            "https://www.pricecharting.com/game/pokemon-base-set/charizard-4"
        );
    }

    function test_callbackStoresSixDecimalPriceUnder200kGas() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(12345);
        (bool ok,) = intake.deliver(id, a, sign(a));
        assertTrue(ok, "200k callback failed");
        (uint256 price, uint64 issued, uint64 expires) = oracle.prices(cardClass);
        assertEq(price, 12345e6);
        assertEq(issued, a.issuedAt);
        assertEq(expires, a.expiresAt);
        assertTrue(oracle.consumed(a.requestId));
        assertEq(oracle.pendingForClass(cardClass), bytes32(0));
    }

    function test_zeroIsStoredButCannotSupportBorrowing() public {
        deliverPrice(0);
        assertEq(oracle.freshPrice(cardClass).price, 0);
        vm.expectRevert();
        vm.prank(alice);
        lending.borrow(tokenId, 1e6);
    }

    function test_wrongCallerUnknownRequestAndReplayRejected() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory sig = sign(a);
        vm.expectRevert(CardOracle.NotIntake.selector);
        oracle.onPrice(id, a, sig);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        _callback(keccak256("wrong"), a, sig);
        _callback(id, a, sig);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        _callback(id, a, sig);
        bytes32 next = ask();
        vm.expectRevert(CardOracle.StalePrice.selector);
        _callback(next, a, sig);
        vm.warp(block.timestamp + 1);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = a.issuedAt + 1 days;
        sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        _callback(next, a, sig);
    }

    function test_tamperingWrongSignerWrongDomainAndWrongChainRejected() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory sig = sign(a);
        a.answer = abi.encode(1_000_000);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, sig);
        a.answer = abi.encode(1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(12345, oracle.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, abi.encodePacked(r, s, v));
        CardOracle other = new CardOracle(address(this), address(intake), address(imd), vm.addr(SIGNER_KEY));
        (v, r, s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        _callback(id, a, abi.encodePacked(r, s, v));
        a.chainId = 56;
        sig = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, sig);
    }

    function test_expiryAndFutureTimestampRejected() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        a.expiresAt = uint64(block.timestamp - 1);
        bytes memory sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        _callback(id, a, sig);
        a.issuedAt = uint64(block.timestamp + 1);
        a.expiresAt = a.issuedAt + 1 days;
        sig = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, sig);
        a.issuedAt = uint64(block.timestamp + 301);
        sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        _callback(id, a, sig);
    }

    function test_timestampMustFollowOpeningAndLifetimeIsBounded() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        --a.issuedAt;
        bytes memory sig = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, sig);
        ++a.issuedAt;
        ++a.expiresAt;
        sig = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, sig);
    }

    function test_panelAgreementAndRequestedMinimumsEnforced() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        a.agreed = 20;
        vm.expectRevert(CardOracle.PanelTooWeak.selector);
        _callback(id, a, "");
        a.agreed = 31;
        vm.expectRevert(CardOracle.PanelTooWeak.selector);
        _callback(id, a, "");
        a.agreed = 25;
        a.quorum = 20;
        vm.expectRevert(CardOracle.PanelTooWeak.selector);
        _callback(id, a, "");
        a.quorum = 21;
        a.panelSize = 29;
        vm.expectRevert(CardOracle.PanelTooWeak.selector);
        _callback(id, a, "");
        oracle.setPanel(5, 4);
        // Updating configuration cannot weaken the original request.
        a.agreed = 5;
        a.panelSize = 5;
        a.quorum = 4;
        vm.expectRevert(CardOracle.PanelTooWeak.selector);
        _callback(id, a, "");
    }

    function test_wrongTypeMalformedAndOversizeAnswersRejected() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        a.answerType = 0;
        bytes memory sig = sign(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(3), uint8(0)));
        _callback(id, a, sig);
        a.answerType = 3;
        a.answer = hex"01";
        sig = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, sig);
        a.answer = abi.encode(oracle.MAX_USD() + 1);
        sig = sign(a);
        vm.expectRevert(CardOracle.BadAttestation.selector);
        _callback(id, a, sig);
    }

    function test_equalOrOlderPriceCannotOverwrite() public {
        deliverPrice(1000);
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(999);
        bytes memory sig = sign(a);
        vm.expectRevert(CardOracle.StalePrice.selector);
        _callback(id, a, sig);
        vm.warp(block.timestamp + 1);
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = a.issuedAt + 1 days;
        _callback(id, a, sign(a));
        assertEq(oracle.freshPrice(cardClass).price, 999e6);
    }

    function test_relayRequiresAdminBindingAndAnyoneCanSubmit() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(2345);
        bytes memory sig = sign(a);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        oracle.submit(a, sig);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        oracle.bindRelay(id, a.requestId, a.questionHash);
        oracle.bindRelay(id, a.requestId, a.questionHash);
        vm.prank(bob);
        oracle.submit(a, sig);
        assertEq(oracle.freshPrice(cardClass).price, 2345e6);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        oracle.submit(a, sig);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        _callback(id, a, sig);
    }

    function test_relayWrongQuestionWrongIdAndRebindingRejected() public {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(1000);
        oracle.bindRelay(id, a.requestId, a.questionHash);
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        oracle.bindRelay(id, a.requestId, a.questionHash);
        a.questionHash = keccak256("unrelated question");
        bytes memory sig = sign(a);
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        oracle.submit(a, sig);
        a.requestId = keccak256("other uuid");
        sig = sign(a);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        oracle.submit(a, sig);
        vm.expectRevert(CardOracle.BadRelayBinding.selector);
        _callback(id, a, sig);
    }

    function test_failureOnlyClearsOwnPendingAndMovesNoValue() public {
        deliverPrice(1000);
        bytes32 id = ask();
        uint256 callerBalance = imd.balanceOf(alice);
        uint256 intakeBalance = imd.balanceOf(address(intake));
        vm.expectRevert(CardOracle.NotIntake.selector);
        oracle.onFailure(id, 1, bytes32("body_invalid"), 0, 0, "");
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        vm.prank(address(intake));
        oracle.onFailure(bytes32("stranger"), 1, bytes32("body_invalid"), 0, 0, "");
        assertTrue(intake.fail(id, 2, bytes32("disagreed")));
        assertEq(oracle.pendingForClass(cardClass), bytes32(0));
        assertEq(imd.balanceOf(alice), callerBalance);
        assertEq(imd.balanceOf(address(intake)), intakeBalance);
        assertEq(oracle.freshPrice(cardClass).price, 1000e6);
        assertFalse(intake.fail(id, 2, bytes32("disagreed")));
    }

    function test_pendingTimeoutBoundaryAllowsRetryWithoutRefund() public {
        bytes32 id = ask();
        uint256 afterPayment = imd.balanceOf(alice);
        vm.expectRevert(CardOracle.ClassBusy.selector);
        ask();
        vm.warp(block.timestamp + oracle.REQUEST_TIMEOUT());
        vm.expectRevert(CardOracle.TooEarly.selector);
        oracle.clearExpired(id);
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        oracle.clearExpired(id);
        assertEq(imd.balanceOf(alice), afterPayment);
        vm.expectRevert(CardOracle.UnknownRequest.selector);
        oracle.clearExpired(id);
        ask();
    }

    function test_callbackAfterDeadlineRejectedEvenIfFresh() public {
        bytes32 id = ask();
        vm.warp(block.timestamp + oracle.REQUEST_TIMEOUT() + 1);
        OracleAttestation.Attestation memory a = attestation(1000);
        bytes memory sig = sign(a);
        vm.expectRevert(CardOracle.RequestExpired.selector);
        _callback(id, a, sig);
        vm.expectRevert(CardOracle.RequestExpired.selector);
        oracle.bindRelay(id, a.requestId, a.questionHash);
    }

    function test_requestConfigSnapshotAllowsOldIntakeToDeliver() public {
        bytes32 id = ask();
        oracle.setIntake(address(new MockIntake()));
        oracle.setObservationChain(56);
        OracleAttestation.Attestation memory a = attestation(1000);
        _callback(id, a, sign(a));
        assertEq(oracle.freshPrice(cardClass).price, 1000e6);
    }

    function test_catalogRejectsUnknownDisabledMalformedAndBusy() public {
        vm.expectRevert(CardOracle.UnknownClass.selector);
        oracle.requestBody(bytes32("none"));
        CardOracle.Template memory t = cardTemplate();
        t.cardName = 'Charizard" inject';
        vm.expectRevert(CardOracle.InvalidTemplate.selector);
        oracle.setClass(cardClass, t, true);
        t = cardTemplate();
        t.cardSlug = "../outside";
        vm.expectRevert(CardOracle.InvalidTemplate.selector);
        oracle.setClass(cardClass, t, true);
        t = cardTemplate();
        t.gradeColumn = "";
        vm.expectRevert(CardOracle.InvalidTemplate.selector);
        oracle.setClass(cardClass, t, true);
        t = cardTemplate();
        oracle.setClass(cardClass, t, false);
        vm.expectRevert(CardOracle.UnknownClass.selector);
        ask();
        oracle.setClass(cardClass, t, true);
        ask();
        vm.expectRevert(CardOracle.ClassBusy.selector);
        oracle.setClass(cardClass, t, false);
    }

    function test_classChangeInvalidatesPreviousPrice() public {
        deliverPrice(1000);
        oracle.setClass(cardClass, cardTemplate(), true);
        vm.expectRevert(CardOracle.StalePrice.selector);
        oracle.freshPrice(cardClass);
    }

    function test_freshnessAtExpiryAndAgeBoundary() public {
        deliverPrice(1000);
        vm.warp(block.timestamp + 1 days);
        assertEq(oracle.freshPrice(cardClass).price, 1000e6);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(CardOracle.StalePrice.selector);
        oracle.freshPrice(cardClass);
    }

    function test_paymentMismatchAndNonPullingIntakeRevertAtomically() public {
        intake.setPrice(1 ether);
        vm.expectRevert(CardOracle.WrongPayment.selector);
        ask();
        intake.setPrice(0.5 ether);
        intake.setTakePayment(false);
        uint256 beforeBalance = imd.balanceOf(alice);
        vm.expectRevert(CardOracle.WrongPayment.selector);
        ask();
        assertEq(imd.balanceOf(alice), beforeBalance);
        assertEq(oracle.pendingForClass(cardClass), bytes32(0));
    }

    function test_configChangesAndPauseAreOwnerControlled() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        oracle.setSigner(alice);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        oracle.setSigner(address(0));
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setPanel(101, 21);
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setPanel(5, 6);
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setObservationChain(0);
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setAction(bytes32(0));
        vm.expectRevert(CardOracle.InvalidConfiguration.selector);
        oracle.setPayment(address(imd), 0);
        oracle.setAction(bytes32("oracle.request@oracle-2"));
        oracle.setPayment(address(imd), 1 ether);
        intake.setPrice(1 ether);
        bytes32 id = ask();
        assertEq(intake.ask(id).action, bytes32("oracle.request@oracle-2"));
        assertEq(intake.ask(id).amount, 1 ether);
        oracle.setGuardian(guardian);
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ask();
        // Settlement must remain live while new requests are paused.
        OracleAttestation.Attestation memory a = attestation(1000);
        _callback(id, a, sign(a));
        oracle.unpause();
    }
}
