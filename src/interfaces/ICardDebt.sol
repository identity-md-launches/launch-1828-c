// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICardDebt {
    function pool() external view returns (address);
    function totalDebt() external view returns (uint256);
}
