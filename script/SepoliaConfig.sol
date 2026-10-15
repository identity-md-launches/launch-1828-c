// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Confirm against the current launch handoff and oracle service before broadcasting.
library SepoliaConfig {
    uint256 internal constant CHAIN_ID = 11155111;
    address internal constant OWNER = 0xD58DCd4594087c2758717A59f44A5Ac09DB65105;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant TEST_IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address internal constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
}
