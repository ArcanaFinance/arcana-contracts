// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// local imports
import {StaticPriceOracle} from "../../../src/oracles/StaticPriceOracle.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/DeployStaticPriceOracle.s.sol:DeployStaticPriceOracle --broadcast --legacy \
    --gas-estimate-multiplier 800 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually (RE.AL):
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/oracles/StaticPriceOracle.sol:StaticPriceOracle --verifier blockscout --verifier-url https://explorer.re.al//api \
    --constructor-args $(cast abi-encode "constructor(address,uint256,uint8)" <TOKEN> <PRICE> <DECIMALS>)
 */

/**
 * @title DeployStaticPriceOracle
 * @author Chase Brown
 * @notice This script deploys a static price oracle for a specific token.
 */
contract DeployStaticPriceOracle is DeployUtility {

    address public TOKEN = 0xc518A88c67CECA8B3f24c4562CB71deeB2AF86B7; // TODO
    uint8 public DECIMALS = 18; // TODO
    uint256 public PRICE = 1 * 10**DECIMALS; // TODO

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(REAL_RPC_URL);
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        address newOracle = address(new StaticPriceOracle(TOKEN, PRICE, DECIMALS));
        console2.log("new oracle address", newOracle);

        vm.stopBroadcast();
    }
}
