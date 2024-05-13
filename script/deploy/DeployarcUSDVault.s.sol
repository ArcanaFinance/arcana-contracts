// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSD} from "../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";
import {CustodianManager} from "../../src/CustodianManager.sol";
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {arcUSDFeeCollector} from "../../src/arcUSDFeeCollector.sol";
import {arcUSDPointsBoostVault} from "../../src/arcUSDPointsBoostingVault.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/DeployarcUSDVault.s.sol:DeployarcUSDVault --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/arcUSDPointsBoostingVault.sol:arcUSDPointsBoostVault --verifier blockscout --verifier-url https://unreal.blockscout.com/api
 */

/**
 * @title DeployarcUSDVault
 * @author Chase Brown
 * @notice This script deploys the arcUSD ecosystem to Unreal chain.
 */
contract DeployarcUSDVault is DeployUtility {
    // ~ Variables ~

    address public arcUSDToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        arcUSDToken = _loadDeploymentAddress("unreal", "arcUSD");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // ----------------
        // Deploy Contracts
        // ----------------

        // Deploy arcUSD Vault
        arcUSDPointsBoostVault arcUSDVault = new arcUSDPointsBoostVault(adminAddress, arcUSDToken);

        // --------------
        // Save Addresses
        // --------------

        _saveDeploymentAddress("unreal", "arcUSDPointsBoostVault", address(arcUSDVault));

        vm.stopBroadcast();
    }
}
