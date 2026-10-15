// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICardDebt {
    function pool() external view returns (address);
    /// @return receivable Active debt plus auction loans marked down the Dutch curve and the linear write-off.
    /// @return expectedShortfall Frozen auction debt above those marks, which the counted reserve may cover.
    function netReceivable() external view returns (uint256 receivable, uint256 expectedShortfall);
}
