// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// local imports
import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSD} from "../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/UpgradearcUSD.s.sol:UpgradearcUSD --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract 0x6f8b3261baef4E86f4e8BD66F64Bb4385ac14083 --chain-id 18233 --watch \
    src/arcUSD.sol:arcUSD --verifier blockscout --verifier-url https://unreal.blockscout.com/api
 */

/**
 * @title UpgradearcUSD
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for arcUSD and upgrades the current proxy.
 */
contract UpgradearcUSD is DeployUtility {
    arcUSD public arcUSDToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        arcUSDToken = arcUSD(_loadDeploymentAddress("unreal", "arcUSD"));
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        arcUSD newarcUSD = new arcUSD(UNREAL_CHAINID, UNREAL_LZ_ENDPOINT_V1);
        arcUSDToken.upgradeToAndCall(address(newarcUSD), "");

        vm.stopBroadcast();
    }
}
