// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// local imports
import {USDa} from "../../src/USDa.sol";
import {IUSDa} from "../../src/interfaces/IUSDa.sol";
import {USDaMinter} from "../../src/USDaMinter.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/UpgradeUSDa.s.sol:UpgradeUSDa --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title UpgradeUSDa
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for USDa and upgrades the current proxy.
 */
contract UpgradeUSDa is DeployUtility {
    USDa public usdaToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        _setUp("unreal");
        usdaToken = USDa(_loadDeploymentAddress("USDa"));
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        USDa newUSDa = new USDa(UNREAL_CHAINID, UNREAL_LZ_ENDPOINT_V2);
        usdaToken.upgradeToAndCall(address(newUSDa), "");

        vm.stopBroadcast();
    }
}
