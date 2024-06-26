// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {AeroLooper} from "../../../src/AeroLooper.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/DeployAeroLooper.s.sol:DeployAeroLooper --broadcast --verify
 */

/**
 * @title DeployAeroLooper
 * @author Chase Brown
 * @notice This script deploys a new AeroLooper to Base.
 */
contract DeployAeroLooper is DeployUtility {
    // constants
    address internal constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43; // TODO
    address internal constant POOL = 0xcDAC0d6c6C59727a65F871236188350531885C43; // TODO

    // env imports
    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public BASE_RPC_URL = vm.envString("BASE_RPC_URL");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(BASE_RPC_URL);
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // deploy AeroLooper implementation
        AeroLooper aeroLooper = new AeroLooper(AERO_ROUTER, address(POOL));
        // deploy proxy
        ERC1967Proxy aeroLooperProxy = new ERC1967Proxy(
            address(aeroLooper),
            abi.encodeWithSelector(AeroLooper.initialize.selector)
        );
        aeroLooper = AeroLooper(payable(address(aeroLooperProxy)));

        // save address
        _saveDeploymentAddress("base", "AeroLooper (WETH/USDC)", address(aeroLooper));

        vm.stopBroadcast();
    }
}
