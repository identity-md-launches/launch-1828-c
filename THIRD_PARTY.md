# Vendored sources

- OpenZeppelin Contracts **v5.5.0**, fetched from `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.5.0`. Solidity files are in `lib/openzeppelin-contracts/contracts`; MIT license in `lib/openzeppelin-contracts/LICENSE`. No package install or submodule is needed.
- forge-std **v1.9.7**, fetched from `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`. Sources are in `lib/forge-std/src`; licenses in `lib/forge-std/LICENSE-MIT` and `lib/forge-std/LICENSE-APACHE`.
- `src/OracleAttestation.sol` is the MIT-licensed canonical protocol source from the assignment's pinned `oracle-consumer/REFERENCE.md`. Protocol struct fields, hashes, domain, verification and decoders are unchanged. `test/OracleConformance.t.sol` retains the reference's exact vector constants and data. Application-specific tests also deliver a numeric variant because CardVault deliberately refuses the vector's bytes32-array price type.
- `src/base/USDC4626.sol` derives from the vendored OpenZeppelin v5.5.0 `ERC4626.sol`, under the same MIT license. Changes: local contract name/import paths; six fixed asset decimals in the constructor; removal of `_tryGetAssetDecimals` and its unused imports; corresponding documentation. Conversion and rounding implementations are unchanged. `CardPool` adds the debt/reserve accounting, six-decimal virtual offset, cash limits and guards.

These copies are ordinary files, with no network fetch during builds. The worker did not copy the unrelated security-reference prose into the application.
