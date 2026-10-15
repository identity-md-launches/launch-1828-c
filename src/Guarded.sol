// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Admin} from "./Admin.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

abstract contract Guarded is Admin, Pausable {
    error NotGuardian();
    address public guardian;
    event GuardianSet(address indexed guardian);

    constructor(address admin) Admin(admin) {
        guardian = admin;
        emit GuardianSet(admin);
    }

    function setGuardian(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        guardian = next;
        emit GuardianSet(next);
    }

    function pause() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
