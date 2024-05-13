// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {arcUSD} from "../../../src/arcUSD.sol";
import {IarcUSD} from "../../../src/interfaces/IarcUSD.sol";
import {arcUSDMinter} from "../../../src/arcUSDMinter.sol";
import {CustodianManager} from "../../../src/CustodianManager.sol";
import {arcUSDTaxManager} from "../../../src/arcUSDTaxManager.sol";
import {arcUSDFeeCollector} from "../../../src/arcUSDFeeCollector.sol";
import {arcUSDPointsBoostVault} from "../../../src/arcUSDPointsBoostingVault.sol";

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
 * @notice This script deploys arcUSD to one or more mainnet satellite chains
 */
contract DeployToReal is DeployUtility {
    // ~ Variables ~

    arcUSD public arcUSDToken;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~
    
    function setUp() public {
        _setup("test.arcUSD.deployment");

        arcUSDToken = arcUSD(_loadDeploymentAddress("re.al", "arcUSD"));
        console.log("arcUSD Address %s", address(arcUSDToken));
    }

    // ~ Script ~

    function run() public {
        vm.createSelectFork(REAL_RPC_URL);
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        // -------------------------
        // Deploy all core contracts
        // -------------------------

        // core contract deployments
        arcUSDFeeCollector feeCollector = arcUSDFeeCollector(_deployFeeCollector());
        arcUSDTaxManager taxManager = arcUSDTaxManager(_deployTaxManager(address(feeCollector)));
        arcUSDMinter arcMinter = arcUSDMinter(_deployarcUSDMinter());
        CustodianManager custodianManager = CustodianManager(_deployCustodianManager(address(arcMinter)));
        arcUSDPointsBoostVault pointsVault = arcUSDPointsBoostVault(_deployPointsBoostingVault());

        //config
        arcMinter.updateCustodian(address(custodianManager));
        arcMinter.addSupportedAsset(REAL_USTB, REAL_USTB_ORACLE);
        arcUSDToken.setMinter(address(arcMinter));
        arcUSDToken.setTaxManager(address(taxManager));

        vm.stopBroadcast();

        
        // ----------------------
        // Save Addresses to JSON
        // ----------------------

        _saveDeploymentAddress("re.al", "arcUSDMinter", address(arcMinter));
        _saveDeploymentAddress("re.al", "CustodianManager", address(custodianManager));
        _saveDeploymentAddress("re.al", "arcUSDTaxManager", address(taxManager));
        _saveDeploymentAddress("re.al", "arcUSDFeeCollector", address(feeCollector));
        _saveDeploymentAddress("re.al", "arcUSDPointsBoostVault", address(pointsVault));
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

        bytes memory bytecode = abi.encodePacked(type(arcUSDFeeCollector).creationCode);

        feeCollectorAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(adminAddress, address(arcUSDToken), distributors, ratios)))
        );

        arcUSDFeeCollector feeCollector;

        if (_isDeployed(feeCollectorAddress)) {
            console.log("arcUSDFeeCollector is already deployed to %s", feeCollectorAddress);
            feeCollector = arcUSDFeeCollector(feeCollectorAddress);
        } else {
            feeCollector = new arcUSDFeeCollector{salt: _SALT}(adminAddress, address(arcUSDToken), distributors, ratios);
            assert(feeCollectorAddress == address(feeCollector));
            console.log("arcUSDFeeCollector deployed to %s", feeCollectorAddress);
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
        bytes memory bytecode = abi.encodePacked(type(arcUSDTaxManager).creationCode);
        taxManagerAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(adminAddress, address(arcUSDToken), feeCollector)))
        );

        arcUSDTaxManager taxManager;

        if (_isDeployed(taxManagerAddress)) {
            console.log("arcUSDTaxManager is already deployed to %s", taxManagerAddress);
            taxManager = arcUSDTaxManager(taxManagerAddress);
        } else {
            taxManager = new arcUSDTaxManager{salt: _SALT}(adminAddress, address(arcUSDToken), feeCollector);
            assert(taxManagerAddress == address(taxManager));
            console.log("arcUSDTaxManager deployed to %s", taxManagerAddress);
        }
    }

    /**
     * @dev This method is in charge of deploying and upgrading arcUSDMinter on any chain.
     * This method will perform the following steps:
     *    - Compute the arcUSDMinter implementation address
     *    - If this address is not deployed, deploy new implementation
     *    - Computes the proxy address. If implementation of that proxy is NOT equal to the arcUSDMinter address computed,
     *      it will upgrade that proxy.
     */
    function _deployarcUSDMinter() internal returns (address arcMinterProxy) {
        bytes memory bytecode = abi.encodePacked(type(arcUSDMinter).creationCode);
        address arcMinterAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(address(arcUSDToken))))
        );

        arcUSDMinter arcMinter;

        if (_isDeployed(arcMinterAddress)) {
            console.log("arcUSDMinter is already deployed to %s", arcMinterAddress);
            arcMinter = arcUSDMinter(arcMinterAddress);
        } else {
            arcMinter = new arcUSDMinter{salt: _SALT}(address(arcUSDToken));
            assert(arcMinterAddress == address(arcMinter));
            console.log("arcUSDMinter deployed to %s", arcMinterAddress);
        }

        bytes memory init = abi.encodeWithSelector(
            arcUSDMinter.initialize.selector,
            adminAddress,
            REAL_JARON,
            adminAddress,
            7 days
        );

        arcMinterProxy = _deployProxy("arcUSDMinter", address(arcMinter), init);
    }

    /**
     * @dev This method is in charge of deploying and upgrading CustodianManager on any chain.
     * This method will perform the following steps:
     *    - Compute the CustodianManager implementation address
     *    - If this address is not deployed, deploy new implementation
     *    - Computes the proxy address. If implementation of that proxy is NOT equal to the CustodianManager address computed,
     *      it will upgrade that proxy.
     */
    function _deployCustodianManager(address arcMinter) internal returns (address custodianManagerProxy) {
        bytes memory bytecode = abi.encodePacked(type(CustodianManager).creationCode);
        address custodianManagerAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(arcMinter)))
        );

        CustodianManager custodianManager;

        if (_isDeployed(custodianManagerAddress)) {
            console.log("CustodianManager is already deployed to %s", custodianManagerAddress);
            custodianManager = CustodianManager(custodianManagerAddress);
        } else {
            custodianManager = new CustodianManager{salt: _SALT}(arcMinter);
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
        bytes memory bytecode = abi.encodePacked(type(arcUSDPointsBoostVault).creationCode);
        pointsBoostingVaultAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(adminAddress, address(arcUSDToken))))
        );

        arcUSDPointsBoostVault arcUSDVault;

        if (_isDeployed(pointsBoostingVaultAddress)) {
            console.log("arcUSDPointsBoostVault is already deployed to %s", pointsBoostingVaultAddress);
            arcUSDVault = arcUSDPointsBoostVault(pointsBoostingVaultAddress);
        } else {
            arcUSDVault = new arcUSDPointsBoostVault{salt: _SALT}(adminAddress, address(arcUSDToken));
            assert(pointsBoostingVaultAddress == address(arcUSDVault));
            console.log("arcUSDPointsBoostVault deployed to %s", pointsBoostingVaultAddress);
        }
    }
}
