// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICardDebt {
    function pool() external view returns (address);
    /// @return receivable Active debt plus auction loans marked at min(debt, current auction price).
    /// @return expectedShortfall Frozen auction debt above those marks, which the reserve may cover.
    function netReceivable() external view returns (uint256 receivable, uint256 expectedShortfall);
}
