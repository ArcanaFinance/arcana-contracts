// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Script.sol";
import {DeployUtility} from "../../DeployUtility.sol";

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {arcUSD as arcUSDToken} from "../../../src/arcUSD.sol";
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
    forge script script/deploy/mainnet/DeployArcUSD.s.sol:DeployArcUSD --broadcast --legacy \
    --gas-estimate-multiplier 600 -vvvv

    @dev To verify manually (RE.AL):
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/arcUSD.sol:arcUSD --verifier blockscout --verifier-url https://explorer.re.al//api

    @dev To verify manually (Base, Optimism, Polygon):
    export ETHERSCAN_API_KEY="<API_KEY>"
    forge verify-contract <CONTRACT_ADDRESS> --chain-id <CHAIN_ID> --watch src/arcUSD.sol:arcUSD \
    --verifier etherscan --constructor-args $(cast abi-encode "constructor(uint256, address)" 111188 <LOCAL_LZ_ADDRESS>)
 */

/**
 * @title DeployArcUSD
 * @author Chase Brown
 * @notice This script deploys arcUSD to one or more mainnet satellite chains
 */
contract DeployArcUSD is DeployUtility {
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
    address public adminAddress = vm.envAddress("DEPLOYER_ADDRESS");

    // ~ Setup ~
    
    function setUp() public {
        _setup("arcUSD.deployment");

        allChains.push(NetworkData(
            {chainName: "re.al", rpc_url: vm.envString("REAL_RPC_URL"), lz_endpoint: REAL_LZ_ENDPOINT_V1, chainId: REAL_LZ_CHAIN_ID_V1, tokenAddress: address(0)}
        ));
        allChains.push(NetworkData(
            {chainName: "optimism", rpc_url: vm.envString("OPTIMISM_RPC_URL"), lz_endpoint: OPTIMISM_LZ_ENDPOINT_V1, chainId: OPTIMISM_LZ_CHAIN_ID_V1, tokenAddress: address(0)}
        ));
        allChains.push(NetworkData(
            {chainName: "base", rpc_url: vm.envString("BASE_RPC_URL"), lz_endpoint: BASE_LZ_ENDPOINT_V1, chainId: BASE_LZ_CHAIN_ID_V1, tokenAddress: address(0)}
        ));
    }

    // ~ Script ~

    function run() public {

        // ---------------------------
        // Deploy all arcUSD cross chain
        // ---------------------------

        uint256 len = allChains.length;
        for (uint256 i; i < len; ++i) {
            if (allChains[i].tokenAddress == address(0)) {

                vm.createSelectFork(allChains[i].rpc_url);
                vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

                address arcUSDAddress = _deployarcUSDToken(REAL_CHAINID, allChains[i].lz_endpoint);

                require(arcUSDAddress > REAL_USTB, "arcUSD address is not greater than USTB");
                require(arcUSDAddress > REAL_MORE, "arcUSD address is not greater than MORE");

                allChains[i].tokenAddress = arcUSDAddress;
                arcUSDToken arcUSD = arcUSDToken(arcUSDAddress);

                // set trusted remote address on all other chains for each token.
                for (uint256 j; j < len; ++j) {
                    if (i != j) {
                        if (
                            !arcUSD.isTrustedRemote(
                                allChains[j].chainId, abi.encodePacked(arcUSDAddress, arcUSDAddress)
                            )
                        ) {
                            arcUSD.setTrustedRemoteAddress(
                                allChains[j].chainId, abi.encodePacked(arcUSDAddress)
                            );
                        }
                    }
                }

                // save arcUSD addresses to appropriate JSON
                _saveDeploymentAddress(allChains[i].chainName, "arcUSD", arcUSDAddress);
                vm.stopBroadcast();
            }
        }
        
        // TODO: Deploy core contracts -> DeployCore
    }

    /**
     * @dev This method is in charge of deploying and upgrading arcUSD on any chain.
     * This method will perform the following steps:
     *    - Compute the arcUSD implementation address
     *    - If this address is not deployed, deploy new implementation
     *    - Computes the proxy address. If implementation of that proxy is NOT equal to the arcUSD address computed,
     *      it will upgrade that proxy.
     */
    function _deployarcUSDToken(uint256 mainChainId, address layerZeroEndpoint) internal returns (address arcUSDProxy) {
        bytes memory bytecode = abi.encodePacked(type(arcUSDToken).creationCode);
        address arcUSDAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(mainChainId, layerZeroEndpoint)))
        );

        arcUSDToken arcUSD;

        if (_isDeployed(arcUSDAddress)) {
            console.log("arcUSD is already deployed to %s", arcUSDAddress);
            arcUSD = arcUSDToken(arcUSDAddress);
        } else {
            arcUSD = new arcUSDToken{salt: _SALT}(mainChainId, layerZeroEndpoint);
            assert(arcUSDAddress == address(arcUSD));
            console.log("arcUSD deployed to %s", arcUSDAddress);
        }

        bytes memory init = abi.encodeWithSelector(
            arcUSDToken.initialize.selector,
            adminAddress,
            UNREAL_REBASE_MANAGER
        );

        arcUSDProxy = _deployProxy("arcUSD", address(arcUSD), init);
    }
}
