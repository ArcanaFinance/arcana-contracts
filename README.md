# Arcana

## Overview

### What is Arcana?

### What is USDa?

## Technical

### Contracts

- [USDa](./src/USDa.sol) - This ERC-20 contract extends the functionality of `LayerZeroRebaseTokenUpgradeable` from [tangible-foundation-contracts](https://github.com/TangibleTNFT/tangible-foundation-contracts/tree/main) to support rebasing and cross-chain bridging.
- [USDaMinter](./src/USDaMinter.sol) - Facilitates the minting and redemption process of USDa tokens against supported ERC-20 collateral assets.
- [USDaFeeCollector](./src/USDaFeeCollector.sol) - This contract receives USDa from rebase fees and distributes them to the necessary recipients.
- [USDaTaxManager](./src/USDaTaxManager.sol) - This contract manages the taxation of rebases on the USDa token.
- [USDaPointsBoostVault](./src/USDaPointsBoostingVault.sol) - This contract represents a points-based system for USDa token holders. By depositing USDa tokens, users receive PTa tokens, which can be redeemed back to USDa.
- [CustodianManager](./src/CustodianManager.sol) - This contract will withdraw from the USDaMinter contract and transfer collateral to the multisig custodian.

### Tests

- [USDaTest](./test/tests/USDa.t.sol) - TODO
- [USDaRebaseTest](./test/tests/USDa.Rebase.t.sol) - TODO
- [USDaLzAppTest](./test/tests/USDa.LzApp.t.sol) - TODO
- [USDaVaultTest](./test/tests/USDa.Vault.t.sol) - TODO
- [USDaFeeCollectorTest](./test/tests/USDaFeeCollector.t.sol) - TODO
- [CustodianManagerTest](./test/tests/CustodianManager.t.sol) - TODO
- [USDaMinterCoreTest](./test/tests/USDaMinter.t.sol) - TODO
- [USDaMinterUSTBIntegrationTest](./test/tests/USDaMinter.USTB.t.sol) - TODO

## Local How-To's

### Env variables

Please refer to [.env.example](./.env.example) for a list of environment variables needed to run tests and scripts, respectively.

### How to build the project

Use forge's native build command to build the project locally:
```
forge b
```
**NOTE**: If your dependancies are not installed, this command should also install all sub dependancies needed.

### How to run tests

Run all unit tests with:
```
forge t
```
**NOTE**: All integration tests will fail if `UNREAL_RPC_URL` is not assigned in your environment variables.

### How to deploy to Unreal

You can deploy & verify all contracts with:
```
forge script script/deploy/DeployToUnreal.s.sol:DeployToUnreal --broadcast --legacy --gas-estimate-multiplier 200 --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
```
**NOTE**:
- All integration tests will fail if `DEPLOYER_PRIVATE_KEY` and `DEPLOYER_ADDRESS` is not assigned in your environment variables.
- The home testnet and mainnet is unreal and re.al respectively. If you wish to deploy to a different chain, additional configuration is required.
- Once deployed, you can see the addresses of your deployed contracts listed in [unreal.json](./deployments/unreal.json).

Go to Unreal Blockscout [here](https://unreal.blockscout.com/).