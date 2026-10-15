// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {TestIMD, MockIntake} from "./helpers/Mocks.sol";

contract VerificationHarness is CardOracle {
    constructor(address admin, address intake_, address imd_, address signer_)
        CardOracle(admin, intake_, imd_, signer_)
    {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature) external view {
        _verifyAttestation(a, signature);
    }
}

/// @dev Constants and vector copied unchanged from the supplied protocol conformance vector.
contract OracleConformanceTest is Test {
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    VerificationHarness internal consumer;
    MockIntake internal intake;
    TestIMD internal imd;
    bytes32 internal cardClass = keccak256("conformance card");

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        intake = new MockIntake();
        imd = new TestIMD();
        deployCodeTo(
            "OracleConformance.t.sol:VerificationHarness",
            abi.encode(address(this), address(intake), address(imd), SIGNER),
            VECTOR_CONSUMER
        );
        consumer = VerificationHarness(VECTOR_CONSUMER);
        consumer.setPanel(5, 4);
        consumer.setClass(
            cardClass,
            CardOracle.Template("Charizard", "4", "Pokemon Base Set", "pokemon-base-set", "charizard-4", "PSA 10"),
            true
        );
        imd.mint(address(this), 10 ether);
        imd.approve(address(consumer), 10 ether);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesProtocolVectorExactly() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function test_protocolSignatureVerifiesWithoutReSigning() public view {
        consumer.verify(vector(), VECTOR_SIGNATURE);
    }

    function test_callbackSelectorIsCanonical() public pure {
        assertEq(
            CardOracle.onPrice.selector,
            bytes4(
                keccak256(
                    "onPrice(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            )
        );
        assertEq(
            CardOracle.onFailure.selector, bytes4(keccak256("onFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)"))
        );
    }

    function test_numericVariantAcceptsVectorSignerThroughIntake() public {
        bytes32 id = consumer.requestPrice(cardClass);
        OracleAttestation.Attestation memory a = vector();
        a.answerType = 3;
        a.answer = abi.encode(uint256(12345));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        (bool ok,) = intake.deliver(id, a, abi.encodePacked(r, s, v));
        assertTrue(ok, "callback failed under 200k gas");
        assertTrue(consumer.consumed(a.requestId));
        assertEq(consumer.freshPrice(cardClass).price, 12345e6);
    }
}
