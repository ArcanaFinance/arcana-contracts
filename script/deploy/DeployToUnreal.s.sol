// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSD} from "../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";
import {CustodianManager} from "../../src/CustodianManager.sol";
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {arcUSDFeeCollector} from "../../src/arcUSDFeeCollector.sol";
import {arcUSDPointsBoostVault} from "../../src/arcUSDPointsBoostingVault.sol";

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
 * @notice This script deploys the arcUSD ecosystem to Unreal chain.
 */
contract DeployToUnreal is DeployUtility {
    // ~ Variables ~

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~

    function setUp() public {
        vm.createSelectFork(UNREAL_RPC_URL);
        //_setUp("unreal");
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

        // Deploy arcUSD token
        // arcUSD arcUSDToken = new arcUSD(UNREAL_CHAINID, UNREAL_LZ_ENDPOINT_V1);
        // ERC1967Proxy arcUSDTokenProxy = new ERC1967Proxy(
        //     address(arcUSDToken),
        //     abi.encodeWithSelector(arcUSD.initialize.selector,
        //         adminAddress,
        //         adminAddress // TODO: RebaseManager
        //     )
        // );
        arcUSD arcUSDToken = arcUSD(_loadDeploymentAddress("unreal", "arcUSD"));

        // Deploy FeeCollector
        arcUSDFeeCollector feeCollector = new arcUSDFeeCollector(adminAddress, address(arcUSDToken), distributors, ratios);

        // Deploy taxManager
        arcUSDTaxManager taxManager = new arcUSDTaxManager(adminAddress, address(arcUSDToken), address(feeCollector));

        // Deploy arcUSDMinter contract.
        arcUSDMinter arcMinter = new arcUSDMinter(address(arcUSDToken));
        ERC1967Proxy arcanaMintingProxy = new ERC1967Proxy(
            address(arcMinter),
            abi.encodeWithSelector(arcUSDMinter.initialize.selector,
                adminAddress,
                UNREAL_JARON,
                adminAddress, // TODO: Whitelister -> Gelato task?
                5 days
            )
        );
        arcMinter = arcUSDMinter(payable(address(arcanaMintingProxy)));

        // Deploy CustodianManager
        CustodianManager custodian = new CustodianManager(address(arcMinter));
        ERC1967Proxy custodianProxy = new ERC1967Proxy(
            address(custodian),
            abi.encodeWithSelector(CustodianManager.initialize.selector,
                adminAddress,
                UNREAL_JARON
            )
        );
        custodian = CustodianManager(address(custodianProxy));

        // Deploy arcUSD Vault
        arcUSDPointsBoostVault arcUSDVault = new arcUSDPointsBoostVault(adminAddress, address(arcUSDToken));

        // ------
        // Config
        // ------

        arcMinter.updateCustodian(address(custodian));

        arcMinter.addSupportedAsset(UNREAL_USTB, UNREAL_USTB_ORACLE);

        arcUSDToken.setMinter(address(arcMinter));

        arcUSDToken.setTaxManager(address(taxManager));

        // --------------
        // Save Addresses
        // --------------

        //_saveDeploymentAddress("unreal", "arcUSD", address(arcUSDToken));
        _saveDeploymentAddress("unreal", "arcUSDMinter", address(arcMinter));
        _saveDeploymentAddress("unreal", "CustodianManager", address(custodian));
        _saveDeploymentAddress("unreal", "arcUSDTaxManager", address(taxManager));
        _saveDeploymentAddress("unreal", "arcUSDFeeCollector", address(feeCollector));
        _saveDeploymentAddress("unreal", "arcUSDPointsBoostVault", address(arcUSDVault));

        vm.stopBroadcast();
    }
}
