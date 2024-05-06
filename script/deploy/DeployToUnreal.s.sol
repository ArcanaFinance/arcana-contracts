// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {USDa} from "../../src/USDa.sol";
import {IUSDa} from "../../src/interfaces/IUSDa.sol";
import {USDaMinter} from "../../src/USDaMinter.sol";
import {CustodianManager} from "../../src/CustodianManager.sol";
import {USDaTaxManager} from "../../src/USDaTaxManager.sol";
import {USDaFeeCollector} from "../../src/USDaFeeCollector.sol";
import {USDaPointsBoostVault} from "../../src/USDaPointsBoostingVault.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/DeployToUnreal.s.sol:DeployToUnreal --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title DeployToUnreal
 * @author Chase Brown
 * @notice This script deploys the USDa ecosystem to Unreal chain.
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
        distributors[1] = adminAddress; // TODO: $ARCANA Escrow or Insurance Fund?

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        // Deploy USDa token
        USDa usdaToken = new USDa(UNREAL_CHAINID, UNREAL_LZ_ENDPOINT_V1);
        ERC1967Proxy usdaTokenProxy = new ERC1967Proxy(
            address(usdaToken),
            abi.encodeWithSelector(USDa.initialize.selector,
                adminAddress,
                adminAddress // TODO: RebaseManager
            )
        );
        usdaToken = USDa(address(usdaTokenProxy));

        // Deploy FeeCollector
        USDaFeeCollector feeCollector = new USDaFeeCollector(adminAddress, address(usdaToken), distributors, ratios);

        // Deploy taxManager
        USDaTaxManager taxManager = new USDaTaxManager(adminAddress, address(usdaToken), address(feeCollector));

        // Deploy USDaMinter contract.
        USDaMinter usdaMinter = new USDaMinter(IUSDa(address(usdaToken)));
        ERC1967Proxy arcanaMintingProxy = new ERC1967Proxy(
            address(usdaMinter),
            abi.encodeWithSelector(USDaMinter.initialize.selector,
                adminAddress,
                UNREAL_JARON,
                adminAddress, // TODO: Whitelister -> Gelato task?
                5 days
            )
        );
        usdaMinter = USDaMinter(payable(address(arcanaMintingProxy)));

        // Deploy CustodianManager
        CustodianManager custodian = new CustodianManager(address(usdaMinter));
        ERC1967Proxy custodianProxy = new ERC1967Proxy(
            address(custodian),
            abi.encodeWithSelector(CustodianManager.initialize.selector,
                adminAddress,
                UNREAL_JARON
            )
        );
        custodian = CustodianManager(address(custodianProxy));

        // Deploy USDa Vault
        USDaPointsBoostVault usdaVault = new USDaPointsBoostVault(address(usdaToken));

        // ------
        // Config
        // ------

        usdaMinter.updateCustodian(address(custodian));

        usdaMinter.addSupportedAsset(UNREAL_USTB, UNREAL_USTB_ORACLE);

        usdaToken.setMinter(address(usdaMinter));

        usdaToken.setSupplyLimit(1_000 * 1e18);

        usdaToken.setTaxManager(address(taxManager));

        // --------------
        // Save Addresses
        // --------------

        _saveDeploymentAddress("USDa", address(usdaToken));
        _saveDeploymentAddress("USDaMinter", address(usdaMinter));
        _saveDeploymentAddress("CustodianManager", address(custodian));
        _saveDeploymentAddress("USDaTaxManager", address(taxManager));
        _saveDeploymentAddress("USDaFeeCollector", address(feeCollector));
        _saveDeploymentAddress("USDaPointsBoostVault", address(usdaVault));

        vm.stopBroadcast();
    }
}
