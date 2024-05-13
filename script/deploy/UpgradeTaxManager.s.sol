// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// local imports
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {arcUSD} from "../../src/arcUSD.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/UpgradeTaxManager.s.sol:UpgradeTaxManager --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title UpgradeTaxManager
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for arcUSD and upgrades the current proxy.
 */
contract UpgradeTaxManager is DeployUtility {
    arcUSDTaxManager public taxManager;
    arcUSD public arcUSDToken;
    address public feeCollector;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        arcUSDToken = arcUSD(_loadDeploymentAddress("unreal", "arcUSD"));
        feeCollector = _loadDeploymentAddress("unreal", "arcUSDFeeCollector");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        arcUSDTaxManager newTaxManager = new arcUSDTaxManager(adminAddress, address(arcUSDToken), feeCollector);

        arcUSDToken.setTaxManager(address(newTaxManager));

        _saveDeploymentAddress("unreal", "arcUSDTaxManager", address(newTaxManager));

        vm.stopBroadcast();
    }
}
