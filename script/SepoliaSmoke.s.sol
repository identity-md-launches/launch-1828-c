// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockCardNFT} from "../src/MockCardNFT.sol";
import {CardPool} from "../src/CardPool.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {CardLending} from "../src/CardLending.sol";
import {SepoliaConfig} from "./SepoliaConfig.sol";

interface ITestIMDMint {
    function mint(address to, uint256 amount) external;
}

/// @notice Two transaction phases: open one real request, then borrow only after a signed result lands.
/// @dev No private keys, environment reads, or mocked delivery. Supply confirmed launch addresses as arguments.
contract SepoliaSmoke is Script {
    function open(
        address usdc_,
        address nft_,
        address pool_,
        address oracle_,
        address lending_,
        string calldata certNumber
    ) external returns (uint256 tokenId, bytes32 intakeId) {
        require(block.chainid == SepoliaConfig.CHAIN_ID, "Sepolia only");
        MockUSDC usdc = MockUSDC(usdc_);
        MockCardNFT nft = MockCardNFT(nft_);
        CardPool pool = CardPool(pool_);
        CardOracle oracle = CardOracle(oracle_);
        CardLending lending = CardLending(lending_);
        require(
            usdc.owner() == SepoliaConfig.OWNER && nft.owner() == SepoliaConfig.OWNER
                && pool.owner() == SepoliaConfig.OWNER && oracle.owner() == SepoliaConfig.OWNER
                && lending.owner() == SepoliaConfig.OWNER,
            "owner mismatch"
        );
        require(
            pool.asset() == usdc_ && address(lending.pool()) == pool_ && address(lending.oracle()) == oracle_
                && address(lending.nft()) == nft_ && address(lending.usdc()) == usdc_,
            "dependency mismatch"
        );
        require(
            oracle.intake() == SepoliaConfig.INTAKE && oracle.paymentAsset() == SepoliaConfig.TEST_IMD
                && oracle.oracleSigner() == SepoliaConfig.ORACLE_SIGNER,
            "oracle configuration mismatch"
        );
        MockCardNFT.Card memory card =
            MockCardNFT.Card("Pokemon", "Pokemon Base Set", "Charizard", "4", "PSA", "10", certNumber);
        bytes32 classId = nft.computeClassId(card);
        require(pool.lending() == lending_ && oracle.allowed(classId), "configure first");
        vm.startBroadcast(SepoliaConfig.OWNER);
        tokenId = nft.mint(SepoliaConfig.OWNER, card);
        nft.approve(lending_, tokenId);
        uint256 fee = oracle.requestFee();
        ITestIMDMint(SepoliaConfig.TEST_IMD).mint(SepoliaConfig.OWNER, fee);
        IERC20(SepoliaConfig.TEST_IMD).approve(oracle_, fee);
        intakeId = oracle.requestPrice(classId);
        vm.stopBroadcast();
        console2.log("Token ID", tokenId);
        console2.log("Intake request ID");
        console2.logBytes32(intakeId);
    }

    /// @notice Run once before preflight. The later open() leaves this reviewed configuration intact.
    function configure(address usdc_, address nft_, address pool_, address oracle_, address lending_) external {
        require(block.chainid == SepoliaConfig.CHAIN_ID, "Sepolia only");
        CardPool pool = CardPool(pool_);
        CardLending lending = CardLending(lending_);
        CardOracle oracle = CardOracle(oracle_);
        require(pool.owner() == SepoliaConfig.OWNER && oracle.owner() == SepoliaConfig.OWNER, "owner mismatch");
        require(
            pool.asset() == usdc_ && address(lending.nft()) == nft_ && address(lending.pool()) == pool_
                && address(lending.oracle()) == oracle_ && address(lending.usdc()) == usdc_,
            "dependency mismatch"
        );
        MockCardNFT.Card memory card =
            MockCardNFT.Card("Pokemon", "Pokemon Base Set", "Charizard", "4", "PSA", "10", "");
        bytes32 classId = MockCardNFT(nft_).computeClassId(card);
        vm.startBroadcast(SepoliaConfig.OWNER);
        if (pool.lending() == address(0)) pool.setLending(lending_);
        require(pool.lending() == lending_, "lending mismatch");
        oracle.setClass(
            classId,
            CardOracle.Template("Charizard", "4", "Pokemon Base Set", "pokemon-base-set", "charizard-4", "PSA 10"),
            true
        );
        IERC20(usdc_).approve(pool_, 1000e6);
        pool.deposit(1000e6, SepoliaConfig.OWNER);
        vm.stopBroadcast();
        console2.log("Class ID");
        console2.logBytes32(classId);
    }

    function finish(address lending_, uint256 tokenId, uint256 grossAmount) external returns (uint256 loanId) {
        require(block.chainid == SepoliaConfig.CHAIN_ID, "Sepolia only");
        CardLending lending = CardLending(lending_);
        require(lending.owner() == SepoliaConfig.OWNER, "owner mismatch");
        require(lending.nft().ownerOf(tokenId) == SepoliaConfig.OWNER, "card owner mismatch");
        // This reverts unless the callback (or a properly bound relay) actually delivered a fresh price.
        CardOracle.Price memory p = lending.oracle().freshPrice(lending.nft().classId(tokenId));
        require(grossAmount > 0 && grossAmount <= p.price * 4500 / 10000, "invalid LTV");
        vm.startBroadcast(SepoliaConfig.OWNER);
        loanId = lending.borrow(tokenId, grossAmount);
        vm.stopBroadcast();
        require(lending.nft().ownerOf(tokenId) == lending_, "collateral not vaulted");
        require(lending.debtOf(loanId) == grossAmount, "unexpected debt");
        console2.log("Loan ID", loanId);
        console2.log("Gross USDC debt (six decimals)", grossAmount);
    }
}
