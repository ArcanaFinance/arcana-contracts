// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// local imports
import {arcUSD} from "../../../src/arcUSD.sol";
import {IarcUSD} from "../../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../../src/arcUSDMinter.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/UpgradeMinter.s.sol:UpgradeMinter --broadcast --legacy \
    --gas-estimate-multiplier 400 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv \
    --constructor-args $(cast abi-encode "constructor(address)" <arcUSD_CONTRACT_ADDRESS>)
 */

/**
 * @title UpgradeMinter
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for arcUSDMinter and upgrades the current proxy.
 */
contract UpgradeMinter is DeployUtility {
    arcUSDMinter public arcMinter;
    address public arcUSDToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(REAL_RPC_URL);
        arcMinter = arcUSDMinter(_loadDeploymentAddress("re.al", "arcUSDMinter"));
        arcUSDToken = _loadDeploymentAddress("re.al", "arcUSD");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        arcUSDMinter newUsdaMinter = new arcUSDMinter(arcUSDToken);
        //arcMinter.upgradeToAndCall(address(newUsdaMinter), ""); TODO: Have multisig call upgradeToAndCall

        vm.stopBroadcast();
    }
}
