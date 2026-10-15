// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {Admin} from "../src/Admin.sol";
import {Guarded} from "../src/Guarded.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockCardNFT} from "../src/MockCardNFT.sol";
import {CardPool} from "../src/CardPool.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {CardLending} from "../src/CardLending.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FactoryProbe {
    function deploy(address owner) external returns (MockUSDC) {
        return new MockUSDC(owner);
    }
}

contract AdminAndTokensTest is Fixture {
    function test_requestedBrandingSixDecimalsInitialSupplyAndMintAuthority() public {
        FactoryProbe factory = new FactoryProbe();
        MockUSDC token = factory.deploy(alice);
        assertEq(token.name(), "C");
        assertEq(token.symbol(), "AUREON");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 1_000_000e6);
        assertEq(token.balanceOf(alice), 1_000_000e6);
        assertEq(token.owner(), alice);
        assertTrue(token.owner() != address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        token.mint(bob, 1e6);
        vm.prank(alice);
        token.mint(bob, 1e6);
        assertEq(token.balanceOf(bob), 1e6);
    }

    function test_twoStepHandoverOnEveryAdminContract() public {
        address[5] memory contracts_ = [address(usdc), address(nft), address(pool), address(oracle), address(lending)];
        for (uint256 i; i < contracts_.length; ++i) {
            Admin a = Admin(contracts_[i]);
            a.transferOwnership(alice);
            assertEq(a.owner(), address(this));
            assertEq(a.pendingOwner(), alice);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
            vm.prank(bob);
            a.acceptOwnership();
            vm.prank(alice);
            a.acceptOwnership();
            assertEq(a.owner(), alice);
            assertEq(a.pendingOwner(), address(0));
            vm.expectRevert(Admin.InvalidAddress.selector);
            vm.prank(alice);
            a.transferOwnership(address(0));
            vm.expectRevert(Admin.RenunciationDisabled.selector);
            vm.prank(alice);
            a.renounceOwnership();
        }
    }

    function test_guardianCanPauseButOnlyAdminUnpauses() public {
        vm.expectRevert(Guarded.NotGuardian.selector);
        vm.prank(bob);
        lending.pause();
        vm.expectRevert(Admin.InvalidAddress.selector);
        lending.setGuardian(address(0));
        lending.setGuardian(guardian);
        vm.prank(guardian);
        lending.pause();
        assertTrue(lending.paused());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        lending.unpause();
        lending.unpause();
        assertFalse(lending.paused());
    }

    function test_cardMetadataImmutableClassesGroupCopiesButNotGrades() public {
        MockCardNFT.Card memory card = nft.cardData(tokenId);
        assertEq(card.game, "Pokemon");
        assertEq(card.set, "Pokemon Base Set");
        assertEq(card.cardName, "Charizard");
        assertEq(card.cardNumber, "4");
        assertEq(card.grader, "PSA");
        assertEq(card.grade, "10");
        assertEq(card.certNumber, "100001");
        uint256 copy = nft.mint(bob, cardMetadata("100002"));
        assertEq(nft.classId(copy), nft.classId(tokenId));
        card.certNumber = "100003";
        card.grade = "9";
        uint256 different = nft.mint(bob, card);
        assertTrue(nft.classId(different) != cardClass);
        vm.expectRevert(MockCardNFT.DuplicateCertificate.selector);
        nft.mint(alice, cardMetadata("100001"));
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
    }

    function test_onlyOwnerMintsNFTAndMetadataIsBounded() public {
        MockCardNFT.Card memory card = cardMetadata("new cert");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        nft.mint(bob, card);
        card.cardName = "";
        vm.expectRevert(MockCardNFT.InvalidMetadata.selector);
        nft.mint(bob, card);
        card.cardName = string(new bytes(129));
        vm.expectRevert(MockCardNFT.InvalidMetadata.selector);
        nft.mint(bob, card);
        vm.expectRevert();
        nft.classId(999);
        vm.expectRevert();
        nft.cardData(999);
    }

    function test_constructorsWorkWithUndeployedDependenciesAndExplicitOwner() public {
        address futureAsset = makeAddr("undeployed asset");
        address futureNFT = makeAddr("undeployed nft");
        address futurePool = makeAddr("undeployed pool");
        address futureOracle = makeAddr("undeployed oracle");
        address futureIntake = makeAddr("undeployed intake");
        CardPool p = new CardPool(alice, IERC20(futureAsset));
        assertEq(p.owner(), alice);
        assertEq(p.asset(), futureAsset);
        assertEq(p.decimals(), 12);
        CardOracle o = new CardOracle(alice, futureIntake, futureAsset, vm.addr(SIGNER_KEY));
        assertEq(o.owner(), alice);
        assertEq(o.guardian(), alice);
        CardLending l = new CardLending(
            alice, MockCardNFT(futureNFT), CardPool(futurePool), CardOracle(futureOracle), IERC20(futureAsset)
        );
        assertEq(l.owner(), alice);
        assertEq(l.guardian(), alice);
        assertEq(address(l.pool()), futurePool);
    }

    function test_runtimeSizeAndForbiddenOpcodesMatchProtectedFloor() public view {
        address[5] memory contracts_ = [address(usdc), address(nft), address(pool), address(oracle), address(lending)];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory code = contracts_[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24576);
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            }
        }
    }
}
