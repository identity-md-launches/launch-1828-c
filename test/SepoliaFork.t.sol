// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "src/MockUSDC.sol";
import {MockCardNFT} from "src/MockCardNFT.sol";
import {CardPool} from "src/CardPool.sol";
import {CardOracle} from "src/CardOracle.sol";
import {CardLending} from "src/CardLending.sol";
import {IIntake} from "src/interfaces/IIntake.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ForkTestIMD {
    function mint(address to, uint256 amount) external;
}

/// @dev Optional read-only forks: no broadcast, private key, fake callback, or
/// RPC dependency in the default offline suite. See test/README.md for inputs.
contract SepoliaForkTest is Test {
    address private constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address private constant IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address private constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;

    function testFork_requestCharizardAgainstRealIntakeCode() public {
        _forkOrSkip();
        assertGt(INTAKE.code.length, 0, "Intake deployment absent");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IIntake(INTAKE).priceOf(bytes32("oracle.request@oracle-1"), IMD), 0.5 ether);

        // These five applications exist only in this fork's memory.
        MockUSDC usdc = new MockUSDC(address(this));
        MockCardNFT nft = new MockCardNFT(address(this));
        CardPool pool = new CardPool(address(this), usdc);
        CardOracle oracle = new CardOracle(address(this), INTAKE, IMD, SIGNER);
        CardLending lending = new CardLending(address(this), nft, pool, oracle, usdc);
        pool.setLending(address(lending));
        usdc.approve(address(pool), 1000e6);
        pool.deposit(1000e6, address(this));
        address borrower = makeAddr("fork-only borrower");
        MockCardNFT.Card memory card =
            MockCardNFT.Card("Pokemon", "Pokemon Base Set", "Charizard", "4", "PSA", "10", "fork-only certificate");
        bytes32 classId = nft.computeClassId(card);
        oracle.setClass(
            classId,
            CardOracle.Template("Charizard", "4", "Pokemon Base Set", "pokemon-base-set", "charizard-4", "PSA 10"),
            true
        );
        uint256 token = nft.mint(borrower, card);
        ForkTestIMD(IMD).mint(borrower, 0.5 ether);
        uint256 beforeCash = IERC20Metadata(IMD).balanceOf(borrower);
        vm.startPrank(borrower);
        IERC20Metadata(IMD).approve(address(oracle), 0.5 ether);
        nft.approve(address(lending), token);
        bytes32 id = oracle.requestPrice(classId);
        vm.stopPrank();
        assertTrue(id != bytes32(0));
        assertTrue(oracle.request(id).pending);
        assertEq(oracle.pendingForClass(classId), id);
        assertEq(IERC20Metadata(IMD).balanceOf(borrower), beforeCash - 0.5 ether);
        assertEq(IERC20Metadata(IMD).balanceOf(address(oracle)), 0);
        assertEq(IERC20Metadata(IMD).allowance(address(oracle), INTAKE), 0);
        vm.expectRevert(CardOracle.StalePrice.selector);
        vm.prank(borrower);
        lending.borrow(token, 400e6);
        assertEq(nft.ownerOf(token), borrower);
        // A fork cannot receive a future service callback. The live script's
        // open/finish phases, and the next test, cover that separate operation.
    }

    function testFork_borrowWithPreviouslyDeliveredLiveAttestation() public {
        _forkOrSkip();
        string memory configured = vm.envOr("CARDVAULT_SEPOLIA_LENDING", string(""));
        if (bytes(configured).length == 0) {
            vm.skip(true);
            return;
        }
        CardLending lending = CardLending(vm.parseAddress(configured));
        uint256 tokenId = vm.envUint("CARDVAULT_SEPOLIA_TOKEN_ID");
        uint256 amount = vm.envUint("CARDVAULT_SEPOLIA_BORROW_AMOUNT");
        MockCardNFT nft = lending.nft();
        address borrower = nft.ownerOf(tokenId);
        assertTrue(borrower != address(lending), "provide an unencumbered minted card");
        CardOracle oracle = lending.oracle();
        assertEq(oracle.intake(), INTAKE);
        assertEq(oracle.paymentAsset(), IMD);
        CardOracle.Price memory quote = oracle.freshPrice(nft.classId(tokenId));
        assertGt(quote.issuedAt, 0, "a real callback or verified relay must have landed");
        assertGt(amount, 1);
        assertLe(amount, quote.price * 45 / 100);
        uint256 beforeCash = lending.usdc().balanceOf(borrower);
        vm.startPrank(borrower);
        nft.approve(address(lending), tokenId);
        uint256 id = lending.borrow(tokenId, amount);
        vm.stopPrank();
        assertEq(nft.ownerOf(tokenId), address(lending));
        assertEq(lending.debtOf(id), amount);
        assertEq(lending.loan(id).borrower, borrower);
        assertEq(lending.usdc().balanceOf(borrower), beforeCash + amount - (amount + 99) / 100);
    }

    function _forkOrSkip() internal {
        string memory rpc = vm.envOr("CARDVAULT_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 11155111, "Sepolia RPC required");
    }
}
