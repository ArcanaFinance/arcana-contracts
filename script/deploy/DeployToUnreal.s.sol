// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {DJUSD} from "../../src/DJUSD.sol";
import {IDJUSD} from "../../src/interfaces/IDJUSD.sol";
import {DJUSDMinting} from "../../src/DJUSDMinting.sol";
import {DJUSDTaxManager} from "../../src/DJUSDTaxManager.sol";
import {DJUSDFeeCollector} from "../../src/DJUSDFeeCollector.sol";
import {DJUSDPointsBoostVault} from "../../src/DJUSDPointsBoostingVault.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
 * @dev To run:
 *         forge script script/deploy/DeployToUnreal.s.sol:DeployToUnreal --broadcast --legacy \
 *         --gas-estimate-multiplier 200 \
 *         --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 *
 *     @dev To verify manually:
 *         forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
 *         src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title DeployToUnreal
 * @author Chase Brown
 * @notice This script deploys the RWA ecosystem to Unreal chain.
 */
contract DeployToUnreal is DeployUtility {
    // ~ Variables ~

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        _setUp("unreal");
    }

    // ~ Script ~

    function run() public {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // ----------------
        // Deploy Contracts
        // ----------------

        address[] memory distributors = new address[](2);
        distributors[0] = UNREAL_REVENUE_DISTRIBUTOR;
        distributors[1] = adminAddress; // TODO: Djinn Escrow

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        // Deploy DJUSD token
        DJUSD djUsdToken = new DJUSD(UNREAL_CHAINID, UNREAL_LZ_ENDPOINT_V2);
        ERC1967Proxy djUsdTokenProxy = new ERC1967Proxy(
            address(djUsdToken),
            abi.encodeWithSelector(
                DJUSD.initialize.selector,
                adminAddress,
                adminAddress // TODO: RebaseManager
            )
        );
        djUsdToken = DJUSD(address(djUsdTokenProxy));

        // Deploy FeeCollector
        DJUSDFeeCollector feeCollector = new DJUSDFeeCollector(adminAddress, address(djUsdToken), distributors, ratios);

        // Deploy taxManager
        DJUSDTaxManager taxManager = new DJUSDTaxManager(adminAddress, address(djUsdToken), address(feeCollector));

        // Deploy DJUSDMinting contract.
        DJUSDMinting djUsdMintingContract = new DJUSDMinting(IDJUSD(address(djUsdToken)));
        ERC1967Proxy djinnMintingProxy = new ERC1967Proxy(
            address(djUsdMintingContract),
            abi.encodeWithSelector(DJUSDMinting.initialize.selector, adminAddress, 5 days, UNREAL_CUSTODIAN)
        );
        djUsdMintingContract = DJUSDMinting(payable(address(djinnMintingProxy)));

        // Deploy DJUSD Vault
        DJUSDPointsBoostVault djUsdVault = new DJUSDPointsBoostVault(address(djUsdToken));

        // ------
        // Config
        // ------

        djUsdMintingContract.addSupportedAsset(UNREAL_USTB, UNREAL_USTB_ORACLE);

        djUsdToken.setMinter(address(djUsdMintingContract));

        djUsdToken.setSupplyLimit(1_000 * 1e18);

        djUsdToken.setTaxManager(address(taxManager));

        // --------------
        // Save Addresses
        // --------------

        _saveDeploymentAddress("DJUSD", address(djUsdToken));
        _saveDeploymentAddress("DJUSDMinting", address(djUsdMintingContract));
        _saveDeploymentAddress("DJUSDTaxManager", address(taxManager));
        _saveDeploymentAddress("DJUSDFeeCollector", address(feeCollector));
        _saveDeploymentAddress("DJUSDPointsBoostVault", address(djUsdVault));

        vm.stopBroadcast();
    }
}
