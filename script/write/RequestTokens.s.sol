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
    forge script script/write/RequestTokens.s.sol:RequestTokens --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title RequestTokens
 * @author Chase Brown
 * @notice This script deploys a new implementation contract for arcUSDMinter and upgrades the current proxy.
 */
contract RequestTokens is DeployUtility {
    arcUSDMinter public arcMinter;
    arcUSD public arcUSDToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        arcMinter = arcUSDMinter(_loadDeploymentAddress("unreal", "arcUSDMinter"));
        arcUSDToken = arcUSD(_loadDeploymentAddress("unreal", "arcUSD"));
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        uint256 amountIn = arcUSDToken.balanceOf(adminAddress); // TODO

        //uint256 getQuote = arcMinter.quoteRedeem(UNREAL_USTB, adminAddress, amountIn);

        arcUSDToken.approve(address(arcMinter), amountIn);
        arcMinter.requestTokens(UNREAL_USTB, amountIn);

        vm.stopBroadcast();
    }
}
