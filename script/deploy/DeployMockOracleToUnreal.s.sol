// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {MockOracle} from "../../test/mock/MockOracle.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/DeployMockOracleToUnreal.s.sol:DeployMockOracleToUnreal --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/arcUSDPointsBoostingVault.sol:arcUSDPointsBoostVault --verifier blockscout --verifier-url https://unreal.blockscout.com/api
 */

/**
 * @title DeployMockOracleToUnreal
 * @author Chase Brown
 * @notice This script deploys the arcUSD ecosystem to Unreal chain.
 */
contract DeployMockOracleToUnreal is DeployUtility {
    // ~ Variables ~

    address public constant reUSDC = 0x4F0253955ceBb45696b4766E0873741ee504220f;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        new MockOracle(
            reUSDC,
            1e18,
            18
        );

        vm.stopBroadcast();
    }
}
