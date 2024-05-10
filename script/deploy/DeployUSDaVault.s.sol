// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {USDa} from "../../src/USDa.sol";
import {IUSDa} from "../../src/interfaces/IUSDa.sol";
import {USDaMinter} from "../../src/USDaMinter.sol";
import {CustodianManager} from "../../src/CustodianManager.sol";
import {USDaTaxManager} from "../../src/USDaTaxManager.sol";
import {USDaFeeCollector} from "../../src/USDaFeeCollector.sol";
import {USDaPointsBoostVault} from "../../src/USDaPointsBoostingVault.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/DeployUSDaVault.s.sol:DeployUSDaVault --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/USDaPointsBoostingVault.sol:USDaPointsBoostVault --verifier blockscout --verifier-url https://unreal.blockscout.com/api
 */

/**
 * @title DeployUSDaVault
 * @author Chase Brown
 * @notice This script deploys the USDa ecosystem to Unreal chain.
 */
contract DeployUSDaVault is DeployUtility {
    // ~ Variables ~

    address public usdaToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        usdaToken = _loadDeploymentAddress("unreal", "USDa");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // ----------------
        // Deploy Contracts
        // ----------------

        // Deploy USDa Vault
        USDaPointsBoostVault usdaVault = new USDaPointsBoostVault(adminAddress, usdaToken);

        // --------------
        // Save Addresses
        // --------------

        _saveDeploymentAddress("unreal", "USDaPointsBoostVault", address(usdaVault));

        vm.stopBroadcast();
    }
}
