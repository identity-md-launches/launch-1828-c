// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {Admin} from "src/Admin.sol";
import {Guarded} from "src/Guarded.sol";
import {MockUSDC} from "src/MockUSDC.sol";
import {MockCardNFT} from "src/MockCardNFT.sol";
import {CardPool} from "src/CardPool.sol";
import {CardOracle} from "src/CardOracle.sol";
import {CardLending} from "src/CardLending.sol";
import {OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract CardAdminEdgesTest is Fixture {
    function test_everyApplicationRejectsZeroAdmin() public {
        bytes memory error = abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0));
        vm.expectRevert(error);
        new MockUSDC(address(0));
        vm.expectRevert(error);
        new MockCardNFT(address(0));
        vm.expectRevert(error);
        new CardPool(address(0), usdc);
        address signer = vm.addr(SIGNER_KEY);
        vm.expectRevert(error);
        new CardOracle(address(0), address(intake), address(imd), signer);
        vm.expectRevert(error);
        new CardLending(address(0), nft, pool, oracle, usdc);
    }

    function test_constructorDependenciesCannotBeZero() public {
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardPool(address(this), IERC20(address(0)));
        address signer = vm.addr(SIGNER_KEY);
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardOracle(address(this), address(0), address(imd), signer);
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardOracle(address(this), address(intake), address(0), signer);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new CardOracle(address(this), address(intake), address(imd), address(0));
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardLending(address(this), MockCardNFT(address(0)), pool, oracle, usdc);
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardLending(address(this), nft, CardPool(address(0)), oracle, usdc);
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardLending(address(this), nft, pool, CardOracle(address(0)), usdc);
        vm.expectRevert(Admin.InvalidAddress.selector);
        new CardLending(address(this), nft, pool, oracle, IERC20(address(0)));
    }

    function test_replacedNomineeCannotAcceptOwnershipOnAnyApplication() public {
        address[5] memory targets = [address(usdc), address(nft), address(pool), address(oracle), address(lending)];
        for (uint256 i; i < targets.length; ++i) {
            Admin application = Admin(targets[i]);
            application.transferOwnership(alice);
            application.transferOwnership(bob);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
            vm.prank(alice);
            application.acceptOwnership();
            assertEq(application.owner(), address(this));
            assertEq(application.pendingOwner(), bob);
            vm.prank(bob);
            application.acceptOwnership();
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
            application.transferOwnership(alice);
            assertEq(application.owner(), bob);
        }
    }

    function test_nominationDoesNotGrantPrematureMintOrRiskAuthority() public {
        usdc.transferOwnership(alice);
        nft.transferOwnership(alice);
        lending.transferOwnership(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        usdc.mint(alice, 1e6);
        MockCardNFT.Card memory card = cardMetadata("unaccepted owner certificate");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        nft.mint(alice, card);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        lending.setAPR(0);
        vm.expectRevert(Guarded.NotGuardian.selector);
        vm.prank(alice);
        lending.pause();
        assertEq(lending.aprBps(), 1200);
        assertFalse(lending.paused());
    }

    function test_guardianRotationAndRepeatedPauseBoundariesOnAllGuardedContracts() public {
        address[3] memory targets = [address(pool), address(oracle), address(lending)];
        for (uint256 i; i < targets.length; ++i) {
            Guarded application = Guarded(targets[i]);
            vm.expectRevert(Admin.InvalidAddress.selector);
            application.setGuardian(address(0));
            application.setGuardian(guardian);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
            vm.prank(guardian);
            application.setGuardian(alice);
            application.setGuardian(alice);
            vm.expectRevert(Guarded.NotGuardian.selector);
            vm.prank(guardian);
            application.pause();
            vm.prank(alice);
            application.pause();
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(alice);
            application.pause();
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
            vm.prank(alice);
            application.unpause();
            application.unpause();
            vm.expectRevert(Pausable.ExpectedPause.selector);
            application.unpause();
        }
    }
}
