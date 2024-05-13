// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/Script.sol";
import {DeployUtility} from "../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {arcUSD} from "../../src/arcUSD.sol";

// helpers
import "../../test/utils/Constants.sol";

/**
    @dev To run:
    forge script script/deploy/DeployarcUSDCrossChain.s.sol:DeployarcUSDCrossChain --broadcast --legacy \
    --gas-estimate-multiplier 200 \
    --verify --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv

    @dev To verify manually:
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 18233 --watch \
    src/Contract.sol:Contract --verifier blockscout --verifier-url https://unreal.blockscout.com/api -vvvv
 */

/**
 * @title DeployarcUSDCrossChain
 * @author Chase Brown
 * @notice This script deploys arcUSD to one or more satellite chains
 */
contract DeployarcUSDCrossChain is DeployUtility {
    // ~ Variables ~

    struct NetworkData {
        string chainName;
        string rpc_url;
        address lz_endpoint;
        uint16 chainId;
        address tokenAddress;
    }

    NetworkData[] internal allChains;

    uint256 public DEPLOYER_PRIVATE_KEY = vm.envUint("DEPLOYER_PRIVATE_KEY");
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    string public SEPOLIA_RPC_URL = vm.envString("SEPOLIA_RPC_URL");
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~
    
    function setUp() public {
        address unreal_arcUSDToken = _loadDeploymentAddress("unreal", "arcUSD");
        address sepolia_arcUSDToken = _loadDeploymentAddress("sepolia", "arcUSD");

        allChains.push(NetworkData(
            {chainName: "unreal", rpc_url: vm.envString("UNREAL_RPC_URL"), lz_endpoint: UNREAL_LZ_ENDPOINT_V1, chainId: UNREAL_LZ_CHAIN_ID_V1, tokenAddress: unreal_arcUSDToken}
        ));
        allChains.push(NetworkData(
            {chainName: "sepolia", rpc_url: vm.envString("SEPOLIA_RPC_URL"), lz_endpoint: SEPOLIA_LZ_ENDPOINT_V1, chainId: SEPOLIA_LZ_CHAIN_ID_V1, tokenAddress: sepolia_arcUSDToken}
        ));
    }

    // ~ Script ~

    function run() public {

        // ----------------
        // Deploy Contracts
        // ----------------

        uint256 len = allChains.length;

        // deploy all tokens
        for (uint256 i; i < len; ++i) {
            if (allChains[i].tokenAddress == address(0)) {

                vm.createSelectFork(allChains[i].rpc_url);
                vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

                address newUsdaToken = _deployarcUSDToken(allChains[i].lz_endpoint);
                allChains[i].tokenAddress = newUsdaToken;

                _saveDeploymentAddress(allChains[i].chainName, "arcUSD", newUsdaToken);
                vm.stopBroadcast();

            }
        }

        for (uint256 i; i < len; ++i) {

            vm.createSelectFork(allChains[i].rpc_url);
            vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

            arcUSD arcUSDToken = arcUSD(allChains[i].tokenAddress);

            for (uint256 j; j < len; ++j) {

                // for token in allChains[i] iterate through allChains setting trusted for all other pairs
                if (i != j) {
                    arcUSDToken.setTrustedRemoteAddress(allChains[j].chainId, abi.encodePacked(address(allChains[j].tokenAddress)));
                }
            }

            vm.stopBroadcast();
        }
    }

    function _deployarcUSDToken(address layerZeroEndpoint) internal returns (address) {
        //bytes memory bytecode = abi.encodePacked(type(arcUSD).creationCode);
        //address arcUSDAddress = vm.computeCreate2Address(_SALT, keccak256(abi.encodePacked(bytecode, abi.encode(UNREAL_CHAINID, layerZeroEndpoint))));
        
        arcUSD arcUSDToken = new arcUSD(UNREAL_CHAINID, layerZeroEndpoint);
        ERC1967Proxy arcUSDTokenProxy = new ERC1967Proxy(
            address(arcUSDToken),
            abi.encodeWithSelector(arcUSD.initialize.selector,
                adminAddress,
                UNREAL_REBASE_MANAGER
            )
        );
        return address(arcUSDTokenProxy);
    }
}
