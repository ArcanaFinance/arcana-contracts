# Arcana

## Overview

The Arcana protocol is an ecosystem of smart contracts that allow investors to partake in a yield generation method that leverages futures trading on centralized exchanges. Investors can mint arcUSD via the arcUSDMinter contract in exchange for stablecoins. The stablecoins will be used by the protocol to generate yield by funding liquidity for CEX futures trading and arcUSD holders will receive yield via rebasing. 

10% of profits from rebases are taken by the protocol via the arcUSDTaxManager which is called upon only when a rebase occurs. The rest of the profit goes to arcUSD holders. arcUSD holders can use their arcUSD to redeem stablecoins from the protocol through the arcUSDMinter contract.

The redeem flow is a 2-step process. Users will need to call arcUSDMinter::requestRedeem which will burn their arcUSD and emit an event that is picked up by an off chain element to start the movement of stablecoins to fulfill that redemption. Redeemers will need to wait 5-7 days (depending on the claimDelay assigned on the arcUSDMinter contract). After the delay has been completed, the redeemer may return and execute claimTokens to claim their redemption.

## Technical

### Contracts

- [arcUSD](./src/arcUSD.sol) - This ERC-20 contract extends the functionality of `LayerZeroRebaseTokenUpgradeable` from [tangible-foundation-contracts](https://github.com/TangibleTNFT/tangible-foundation-contracts/tree/main) to support rebasing and cross-chain bridging.
- [arcUSDMinter](./src/arcUSDMinter.sol) - Facilitates the minting and redemption process of arcUSD tokens against supported ERC-20 collateral assets.
- [arcUSDFeeCollector](./src/arcUSDFeeCollector.sol) - This contract receives arcUSD from rebase fees and distributes them to the necessary recipients.
- [arcUSDTaxManager](./src/arcUSDTaxManager.sol) - This contract manages the taxation of rebases on the arcUSD token.
- [arcUSDPointsBoostVault](./src/arcUSDPointsBoostingVault.sol) - This contract represents a points-based system for arcUSD token holders. By depositing arcUSD tokens, users receive PTa tokens, which can be redeemed back to arcUSD.
- [CustodianManager](./src/CustodianManager.sol) - This contract will withdraw from the arcUSDMinter contract and transfer collateral to the multisig custodian.

### Tests

- [arcUSDTest](./test/tests/arcUSD.t.sol) - Core unit tests for arcUSD basic functionality.
- [arcUSDRebaseTest](./test/tests/arcUSD.Rebase.t.sol) - Contains unit tests for rebase-based functionality for arcUSD.
- [arcUSDLzAppTest](./test/tests/arcUSD.LzApp.t.sol) - Contains unit tests for LayerZero App setters.
- [arcUSDVaultTest](./test/tests/arcUSD.Vault.t.sol) - Unit Tests for arcUSDPointsBoostVault contract interactions.
- [arcUSDFeeCollectorTest](./test/tests/arcUSDFeeCollector.t.sol) - Unit Tests for arcUSDFeeCollector contract interactions.
- [CustodianManagerTest](./test/tests/CustodianManager.t.sol) - Unit Tests for CustodianManager contract interactions.
- [arcUSDMinterCoreTest](./test/tests/arcUSDMinter.t.sol) - Core unit tests for arcUSDMinter contract functionality.
- [arcUSDMinterUSTBIntegrationTest](./test/tests/arcUSDMinter.USTB.t.sol) - Contains integration tests for arcUSDMinter when USTB is the collateral token.

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
