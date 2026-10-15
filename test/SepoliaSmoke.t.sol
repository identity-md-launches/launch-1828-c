// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockCardNFT} from "../src/MockCardNFT.sol";
import {CardPool} from "../src/CardPool.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {CardLending} from "../src/CardLending.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIntake, TestIMD} from "./helpers/Mocks.sol";
import {SepoliaSmoke} from "../script/SepoliaSmoke.s.sol";
import {SepoliaConfig} from "../script/SepoliaConfig.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @dev Local ERC-1271 mock only. No signature claiming to come from the live oracle is generated.
contract TestSignerRegistry {
    address private immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract SepoliaSmokeTest is Fixture {
    SepoliaSmoke internal smoke;

    function setUp() public override {
        vm.chainId(SepoliaConfig.CHAIN_ID);
        vm.warp(1_800_000_000);
        // Only the test etches mocks. The delivered smoke script calls the actual Sepolia contracts.
        TestIMD imdImplementation = new TestIMD();
        vm.etch(SepoliaConfig.TEST_IMD, address(imdImplementation).code);
        imd = TestIMD(SepoliaConfig.TEST_IMD);
        MockIntake intakeImplementation = new MockIntake();
        vm.etch(SepoliaConfig.INTAKE, address(intakeImplementation).code);
        intake = MockIntake(SepoliaConfig.INTAKE);
        intake.setPrice(0.5 ether);
        intake.setTakePayment(true);
        TestSignerRegistry registry = new TestSignerRegistry(vm.addr(SIGNER_KEY));
        vm.etch(SepoliaConfig.ORACLE_SIGNER, address(registry).code);
        usdc = new MockUSDC(SepoliaConfig.OWNER);
        nft = new MockCardNFT(SepoliaConfig.OWNER);
        pool = new CardPool(SepoliaConfig.OWNER, usdc);
        oracle = new CardOracle(
            SepoliaConfig.OWNER, SepoliaConfig.INTAKE, SepoliaConfig.TEST_IMD, SepoliaConfig.ORACLE_SIGNER
        );
        lending = new CardLending(SepoliaConfig.OWNER, nft, pool, oracle, usdc);
        cardClass = nft.computeClassId(cardMetadata("script cert"));
        smoke = new SepoliaSmoke();
    }

    function test_scriptOpensExactlyOneRequestThenBorrowsOnlyAfterCallback() public {
        smoke.configure(address(usdc), address(nft), address(pool), address(oracle), address(lending));
        (uint256 minted, bytes32 id) =
            smoke.open(address(usdc), address(nft), address(pool), address(oracle), address(lending), "script cert");
        assertEq(intake.nonce(), 1);
        assertEq(oracle.pendingForClass(cardClass), id);
        assertEq(pool.totalAssets(), 1000e6);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        vm.expectRevert(CardOracle.StalePrice.selector);
        smoke.finish(address(lending), minted, 400e6);
        OracleAttestation.Attestation memory a = attestation(1000);
        (bool ok,) = intake.deliver(id, a, sign(a));
        assertTrue(ok, "ERC1271 callback exceeds 200k or failed");
        uint256 ownerCash = usdc.balanceOf(SepoliaConfig.OWNER);
        uint256 loanId = smoke.finish(address(lending), minted, 400e6);
        assertEq(lending.debtOf(loanId), 400e6);
        assertEq(nft.ownerOf(minted), address(lending));
        assertEq(usdc.balanceOf(SepoliaConfig.OWNER), ownerCash + 396e6);
        assertEq(pool.reserve(), 4e6);
    }

    function test_scriptRefusesWrongChainBeforeAnyPayment() public {
        vm.chainId(1);
        vm.expectRevert("Sepolia only");
        smoke.configure(address(usdc), address(nft), address(pool), address(oracle), address(lending));
        assertEq(intake.nonce(), 0);
    }
}
