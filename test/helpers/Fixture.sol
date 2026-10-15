// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {MockCardNFT} from "../../src/MockCardNFT.sol";
import {CardPool} from "../../src/CardPool.sol";
import {CardOracle} from "../../src/CardOracle.sol";
import {CardLending} from "../../src/CardLending.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../../src/OracleAttestation.sol";
import {TestIMD, MockIntake} from "./Mocks.sol";

abstract contract Fixture is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal lender = makeAddr("lender");
    address internal guardian = makeAddr("guardian");
    MockUSDC internal usdc;
    MockCardNFT internal nft;
    CardPool internal pool;
    CardOracle internal oracle;
    CardLending internal lending;
    TestIMD internal imd;
    MockIntake internal intake;
    bytes32 internal cardClass;
    uint256 internal tokenId;
    uint256 internal oracleNonce;

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        vm.roll(1_000);
        usdc = new MockUSDC(address(this));
        nft = new MockCardNFT(address(this));
        pool = new CardPool(address(this), usdc);
        imd = new TestIMD();
        intake = new MockIntake();
        oracle = new CardOracle(address(this), address(intake), address(imd), vm.addr(SIGNER_KEY));
        lending = new CardLending(address(this), nft, pool, oracle, usdc);
        pool.setLending(address(lending));
        MockCardNFT.Card memory card = cardMetadata("100001");
        cardClass = nft.computeClassId(card);
        tokenId = nft.mint(alice, card);
        oracle.setClass(cardClass, cardTemplate(), true);
        imd.mint(alice, 100 ether);
        imd.mint(bob, 100 ether);
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(alice);
        imd.approve(address(oracle), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        nft.setApprovalForAll(address(lending), true);
        vm.stopPrank();
        vm.startPrank(bob);
        imd.approve(address(oracle), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(10_000e6, lender);
        vm.stopPrank();
    }

    function cardMetadata(string memory cert) internal pure returns (MockCardNFT.Card memory) {
        return MockCardNFT.Card("Pokemon", "Pokemon Base Set", "Charizard", "4", "PSA", "10", cert);
    }

    function cardTemplate() internal pure returns (CardOracle.Template memory) {
        return CardOracle.Template("Charizard", "4", "Pokemon Base Set", "pokemon-base-set", "charizard-4", "PSA 10");
    }

    function ask() internal returns (bytes32 id) {
        vm.prank(alice);
        id = oracle.requestPrice(cardClass);
    }

    function attestation(uint256 dollars) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("oracle UUID", ++oracleNonce));
        a.chainId = 1;
        a.questionHash = keccak256("canonical question document");
        a.answerType = 3;
        a.answer = abi.encode(dollars);
        a.figure = dollars;
        a.fromBlock = 100;
        a.toBlock = 900;
        a.blockHash = keccak256("closing block");
        a.panelJobId = keccak256("panel UUID");
        a.panelSize = 30;
        a.quorum = 21;
        a.agreed = 25;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, oracle.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function deliverPrice(uint256 dollars) internal {
        bytes32 id = ask();
        OracleAttestation.Attestation memory a = attestation(dollars);
        (bool ok, bytes memory reason) = intake.deliver(id, a, sign(a));
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }

    function borrow(uint256 amount) internal returns (uint256 id) {
        deliverPrice(1000);
        vm.prank(alice);
        id = lending.borrow(tokenId, amount);
    }

    function getLoan(uint256 id) internal view returns (CardLending.Loan memory l) {
        return lending.loan(id);
    }

    function _callback(bytes32 id, OracleAttestation.Attestation memory a, bytes memory sig) internal {
        vm.prank(address(intake));
        oracle.onPrice(id, a, sig);
    }
}
