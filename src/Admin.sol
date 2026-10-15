// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Explicit factory-safe ownership; every handover requires acceptance.
abstract contract Admin is Ownable2Step {
    error InvalidAddress();
    error RenunciationDisabled();

    constructor(address admin) Ownable(admin) {}

    function transferOwnership(address next) public override onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        super.transferOwnership(next);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }
}
