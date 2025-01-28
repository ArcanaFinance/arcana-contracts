// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local imports
import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSD} from "../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/write/ModifyWhitelist.s.sol:ModifyWhitelist --broadcast --legacy \
    --gas-estimate-multiplier 700 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title ModifyWhitelist
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for arcUSDMinter and upgrades the current proxy.
 */
contract ModifyWhitelist is DeployUtility {
    arcUSDMinter public arcMinter;

    address public addressToWhitelist = 0x63Cd04630E9C6eCa572Fd39863B63ce6117eC86b;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        arcMinter = arcUSDMinter(_loadDeploymentAddress("unreal", "arcUSDMinter"));
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        arcMinter.modifyWhitelist(addressToWhitelist, true);

        vm.stopBroadcast();
    }
}
