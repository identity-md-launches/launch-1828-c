// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Admin} from "./Admin.sol";

/// @notice Test-only USDC denomination, with the requested C / AUREON branding.
contract MockUSDC is ERC20, Admin {
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e6;

    constructor(address admin) ERC20("C", "AUREON") Admin(admin) {
        _mint(admin, INITIAL_SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
