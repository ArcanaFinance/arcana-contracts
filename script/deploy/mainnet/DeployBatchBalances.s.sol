// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// local imports
import {BatchBalances} from "../../../src/helpers/BatchBalances.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/DeployBatchBalances.s.sol:DeployBatchBalances --broadcast --legacy \
    --gas-estimate-multiplier 800 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/helpers/BatchBalances.sol:BatchBalances --verifier blockscout --verifier-url https://explorer.re.al//api
 */

/**
 * @title DeployBatchBalances
 * @author Chase Brown
 * @notice This script deploys a BatchBalances contract to unreal.
 */
contract DeployBatchBalances is DeployUtility {
    // ~ Variables ~

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(REAL_RPC_URL);
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        new BatchBalances();

        vm.stopBroadcast();
    }
}
