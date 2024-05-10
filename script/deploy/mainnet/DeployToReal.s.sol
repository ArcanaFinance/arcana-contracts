// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {USDa} from "../../../src/USDa.sol";
import {IUSDa} from "../../../src/interfaces/IUSDa.sol";
import {USDaMinter} from "../../../src/USDaMinter.sol";
import {CustodianManager} from "../../../src/CustodianManager.sol";
import {USDaTaxManager} from "../../../src/USDaTaxManager.sol";
import {USDaFeeCollector} from "../../../src/USDaFeeCollector.sol";
import {USDaPointsBoostVault} from "../../../src/USDaPointsBoostingVault.sol";

// helpers
import "../../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/mainnet/DeployToReal.s.sol:DeployToReal --broadcast --legacy \
    --gas-estimate-multiplier 600 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://explorer.re.al//api
 */

/**
 * @title DeployToReal
 * @author Chase Brown
 * @notice This script deploys USDa to one or more mainnet satellite chains
 */
contract DeployToReal is DeployUtility {
    // ~ Variables ~

    USDa public usdaToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~
    
    function setUp() public {
        _setup("test.USDa.deployment");

        usdaToken = USDa(_loadDeploymentAddress("re.al", "USDa"));
        console.log("USDa Address %s", address(usdaToken));
    }

    // ~ Script ~

    function run() public {
        vm.createSelectFork(REAL_RPC_URL);
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // -------------------------
        // Deploy all core contracts
        // -------------------------

        // core contract deployments
        USDaFeeCollector feeCollector = USDaFeeCollector(_deployFeeCollector());
        USDaTaxManager taxManager = USDaTaxManager(_deployTaxManager(address(feeCollector)));
        USDaMinter usdaMinter = USDaMinter(_deployUSDaMinter());
        CustodianManager custodianManager = CustodianManager(_deployCustodianManager(address(usdaMinter)));
        USDaPointsBoostVault pointsVault = USDaPointsBoostVault(_deployPointsBoostingVault());

        //config
        usdaMinter.updateCustodian(address(custodianManager));
        usdaMinter.addSupportedAsset(REAL_USTB, REAL_USTB_ORACLE);
        usdaToken.setMinter(address(usdaMinter));
        usdaToken.setTaxManager(address(taxManager));

        vm.stopBroadcast();

        
        // ----------------------
        // Save Addresses to JSON
        // ----------------------

        _saveDeploymentAddress("re.al", "USDaMinter", address(usdaMinter));
        _saveDeploymentAddress("re.al", "CustodianManager", address(custodianManager));
        _saveDeploymentAddress("re.al", "USDaTaxManager", address(taxManager));
        _saveDeploymentAddress("re.al", "USDaFeeCollector", address(feeCollector));
        _saveDeploymentAddress("re.al", "USDaPointsBoostVault", address(pointsVault));
    }
    
    /**
     * @dev This method is in charge of deploying a new FeeCollector, if one does not already exist.
     * This method will perform the following steps:
     *    - Compute the FeeCollector address
     *    - If this address is not deployed, deploy new contract
     */
    function _deployFeeCollector() internal returns (address feeCollectorAddress) {
        address[] memory distributors = new address[](2);
        distributors[0] = REAL_JARON; // TODO: RWA:RevenueDistributor
        distributors[1] = REAL_JARON; // TODO: $ARCANA Escrow or Insurance Fund?

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        bytes memory bytecode = abi.encodePacked(type(USDaFeeCollector).creationCode);

        feeCollectorAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(adminAddress, address(usdaToken), distributors, ratios)))
        );

        USDaFeeCollector feeCollector;

        if (_isDeployed(feeCollectorAddress)) {
            console.log("USDaFeeCollector is already deployed to %s", feeCollectorAddress);
            feeCollector = USDaFeeCollector(feeCollectorAddress);
        } else {
            feeCollector = new USDaFeeCollector{salt: _SALT}(adminAddress, address(usdaToken), distributors, ratios);
            assert(feeCollectorAddress == address(feeCollector));
            console.log("USDaFeeCollector deployed to %s", feeCollectorAddress);
        }
    }

    /**
     * @dev This method is in charge of deploying a new TaxManager, if one does not already exist.
     * This method will perform the following steps:
     *    - Compute the TaxManager address
     *    - If this address is not deployed, deploy new contract
     *    - If the computer taxManager is already deployed, it will update the feeCollector if the
     *      current TaxManager::feeCollector does not match `feeCollector`
     */
    function _deployTaxManager(address feeCollector) internal returns (address taxManagerAddress) {
        bytes memory bytecode = abi.encodePacked(type(USDaTaxManager).creationCode);
        taxManagerAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(adminAddress, address(usdaToken), feeCollector)))
        );

        USDaTaxManager taxManager;

        if (_isDeployed(taxManagerAddress)) {
            console.log("USDaTaxManager is already deployed to %s", taxManagerAddress);
            taxManager = USDaTaxManager(taxManagerAddress);
        } else {
            taxManager = new USDaTaxManager{salt: _SALT}(adminAddress, address(usdaToken), feeCollector);
            assert(taxManagerAddress == address(taxManager));
            console.log("USDaTaxManager deployed to %s", taxManagerAddress);
        }
    }

    /**
     * @dev This method is in charge of deploying and upgrading USDaMinter on any chain.
     * This method will perform the following steps:
     *    - Compute the USDaMinter implementation address
     *    - If this address is not deployed, deploy new implementation
     *    - Computes the proxy address. If implementation of that proxy is NOT equal to the USDaMinter address computed,
     *      it will upgrade that proxy.
     */
    function _deployUSDaMinter() internal returns (address usdaMinterProxy) {
        bytes memory bytecode = abi.encodePacked(type(USDaMinter).creationCode);
        address usdaMinterAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(address(usdaToken))))
        );

        USDaMinter usdaMinter;

        if (_isDeployed(usdaMinterAddress)) {
            console.log("USDaMinter is already deployed to %s", usdaMinterAddress);
            usdaMinter = USDaMinter(usdaMinterAddress);
        } else {
            usdaMinter = new USDaMinter{salt: _SALT}(address(usdaToken));
            assert(usdaMinterAddress == address(usdaMinter));
            console.log("USDaMinter deployed to %s", usdaMinterAddress);
        }

        bytes memory init = abi.encodeWithSelector(
            USDaMinter.initialize.selector,
            adminAddress,
            REAL_JARON,
            adminAddress,
            7 days
        );

        usdaMinterProxy = _deployProxy("USDaMinter", address(usdaMinter), init);
    }

    /**
     * @dev This method is in charge of deploying and upgrading CustodianManager on any chain.
     * This method will perform the following steps:
     *    - Compute the CustodianManager implementation address
     *    - If this address is not deployed, deploy new implementation
     *    - Computes the proxy address. If implementation of that proxy is NOT equal to the CustodianManager address computed,
     *      it will upgrade that proxy.
     */
    function _deployCustodianManager(address usdaMinter) internal returns (address custodianManagerProxy) {
        bytes memory bytecode = abi.encodePacked(type(CustodianManager).creationCode);
        address custodianManagerAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(usdaMinter)))
        );

        CustodianManager custodianManager;

        if (_isDeployed(custodianManagerAddress)) {
            console.log("CustodianManager is already deployed to %s", custodianManagerAddress);
            custodianManager = CustodianManager(custodianManagerAddress);
        } else {
            custodianManager = new CustodianManager{salt: _SALT}(usdaMinter);
            assert(custodianManagerAddress == address(custodianManager));
            console.log("CustodianManager deployed to %s", custodianManagerAddress);
        }

        bytes memory init = abi.encodeWithSelector(
            CustodianManager.initialize.selector,
            adminAddress,
            REAL_JARON // TODO: Multisig?
        );

        custodianManagerProxy = _deployProxy("CustodianManager", address(custodianManager), init);
    }

    /**
     * @dev This method is in charge of deploying a new PointsBoostVault, if one does not already exist.
     * This method will perform the following steps:
     *    - Compute the PointsBoostVault address
     *    - If this address is not deployed, deploy new contract
     */
    function _deployPointsBoostingVault() internal returns (address pointsBoostingVaultAddress) {
        bytes memory bytecode = abi.encodePacked(type(USDaPointsBoostVault).creationCode);
        pointsBoostingVaultAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(adminAddress, address(usdaToken))))
        );

        USDaPointsBoostVault usdaVault;

        if (_isDeployed(pointsBoostingVaultAddress)) {
            console.log("USDaPointsBoostVault is already deployed to %s", pointsBoostingVaultAddress);
            usdaVault = USDaPointsBoostVault(pointsBoostingVaultAddress);
        } else {
            usdaVault = new USDaPointsBoostVault{salt: _SALT}(adminAddress, address(usdaToken));
            assert(pointsBoostingVaultAddress == address(usdaVault));
            console.log("USDaPointsBoostVault deployed to %s", pointsBoostingVaultAddress);
        }
    }
}
