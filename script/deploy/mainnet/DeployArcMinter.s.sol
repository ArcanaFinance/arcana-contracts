// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// local imports
import {arcUSD} from "../../../src/arcUSD.sol";
import {IarcUSD} from "../../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../../src/arcUSDMinter.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/DeployArcMinter.s.sol:DeployArcMinter --broadcast --legacy \
    --gas-estimate-multiplier 600 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/arcUSD.sol:arcUSD --verifier blockscout --verifier-url https://explorer.re.al//api \
    --constructor-args $(cast abi-encode "constructor(address)" 0xAEC9e50e3397f9ddC635C6c429C8C7eca418a143)
 */

/**
 * @title DeployArcMinter
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for arcUSDMinter.
 */
contract DeployArcMinter is DeployUtility {
    address public arcUSDToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(REAL_RPC_URL);
        arcUSDToken = _loadDeploymentAddress("re.al", "arcUSD");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        arcUSDMinter newArcMinter = new arcUSDMinter(arcUSDToken);
        console.log(address(newArcMinter));

        vm.stopBroadcast();
    }
}
