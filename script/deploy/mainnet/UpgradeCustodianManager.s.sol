// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// local imports
import {CustodianManager} from "../../../src/CustodianManager.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/UpgradeCustodianManager.s.sol:UpgradeCustodianManager --broadcast --legacy \
    --gas-estimate-multiplier 400 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually (RE.AL):
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/CustodianManager.sol:CustodianManager --verifier blockscout --verifier-url https://explorer.re.al//api \
    --constructor-args $(cast abi-encode "constructor(address)" <arcUSDMinter_CONTRACT_ADDRESS>)
 */

/**
 * @title UpgradeCustodianManager
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for CustodianManager and upgrades the current proxy.
 */
contract UpgradeCustodianManager is DeployUtility {
    CustodianManager public custodianManager;
    address public arcMinter;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(REAL_RPC_URL);
        custodianManager = CustodianManager(_loadDeploymentAddress("re.al", "CustodianManager"));
        arcMinter = _loadDeploymentAddress("re.al", "arcUSDMinter");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        CustodianManager newCustodianManager = new CustodianManager(arcMinter);
        custodianManager.upgradeToAndCall(address(newCustodianManager), "");

        vm.stopBroadcast();
    }
}
