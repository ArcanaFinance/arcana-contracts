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
    forge script script/deploy/UpgradeMinter.s.sol:UpgradeMinter --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title UpgradeMinter
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for USDaMinter and upgrades the current proxy.
 */
contract UpgradeMinter is DeployUtility {
    USDaMinter public usdaMinter;
    address public usdaToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        _setUp("unreal");
        usdaMinter = USDaMinter(_loadDeploymentAddress("USDaMinter"));
        usdaToken = _loadDeploymentAddress("USDa");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        USDaMinter newDjUsdMinter = new USDaMinter(IUSDa(usdaToken));
        usdaMinter.upgradeToAndCall(address(newDjUsdMinter), "");

        vm.stopBroadcast();
    }
}
