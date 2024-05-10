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
    forge script script/deploy/mainnet/DeployAll.s.sol:DeployAll --broadcast --legacy \
    --gas-estimate-multiplier 600 \
    --verify --verifier blockscout --verifier-url https://explorer.re.al//api -vvvv

    @dev To verify manually (RE.AL):
    forge verify-contract <CONTRACT_ADDRESS> --chain-id 111188 --watch \
    src/USDa.sol:USDa --verifier blockscout --verifier-url https://explorer.re.al//api

    @dev To verify manually (Base, Optimism, Polygon):
    export ETHERSCAN_API_KEY="<API_KEY>"
    forge verify-contract <CONTRACT_ADDRESS> --chain-id <CHAIN_ID> --watch src/USDa.sol:USDa \
    --verifier etherscan --constructor-args $(cast abi-encode "constructor(uint256, address)" 111188 <LOCAL_LZ_ADDRESS>)
 */

/**
 * @title DeployAll
 * @author Chase Brown
 * @notice This script deploys USDa to one or more mainnet satellite chains
 */
contract DeployAll is DeployUtility {
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
        _setup("test.USDa.deployment");

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
        // Deploy all USDa cross chain
        // ---------------------------

        uint256 len = allChains.length;
        for (uint256 i; i < len; ++i) {
            if (allChains[i].tokenAddress == address(0)) {

                vm.createSelectFork(allChains[i].rpc_url);
                vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

                address usdaAddress = _deployUSDaToken(REAL_CHAINID, allChains[i].lz_endpoint);

                require(usdaAddress > REAL_USTB, "USDa address is not greater than USTB");
                require(usdaAddress > REAL_MORE, "USDa address is not greater than MORE");

                allChains[i].tokenAddress = usdaAddress;
                USDa usda = USDa(usdaAddress);

                // set trusted remote address on all other chains for each token.
                for (uint256 j; j < len; ++j) {
                    if (i != j) {
                        if (
                            !usda.isTrustedRemote(
                                allChains[j].chainId, abi.encodePacked(usdaAddress, usdaAddress)
                            )
                        ) {
                            usda.setTrustedRemoteAddress(
                                allChains[j].chainId, abi.encodePacked(usdaAddress)
                            );
                        }
                    }
                }

                // save USDa addresses to appropriate JSON
                _saveDeploymentAddress(allChains[i].chainName, "USDa", usdaAddress);
                vm.stopBroadcast();
            }
        }
        
        // TODO: Deploy core contracts
    }

    /**
     * @dev This method is in charge of deploying and upgrading USDa on any chain.
     * This method will perform the following steps:
     *    - Compute the USDa implementation address
     *    - If this address is not deployed, deploy new implementation
     *    - Computes the proxy address. If implementation of that proxy is NOT equal to the USDa address computed,
     *      it will upgrade that proxy.
     */
    function _deployUSDaToken(uint256 mainChainId, address layerZeroEndpoint) internal returns (address usdaProxy) {
        bytes memory bytecode = abi.encodePacked(type(USDa).creationCode);
        address usdaAddress = vm.computeCreate2Address(
            _SALT, keccak256(abi.encodePacked(bytecode, abi.encode(mainChainId, layerZeroEndpoint)))
        );

        USDa usdaToken;

        if (_isDeployed(usdaAddress)) {
            console.log("USDa is already deployed to %s", usdaAddress);
            usdaToken = USDa(usdaAddress);
        } else {
            usdaToken = new USDa{salt: _SALT}(mainChainId, layerZeroEndpoint);
            assert(usdaAddress == address(usdaToken));
            console.log("USDa deployed to %s", usdaAddress);
        }

        bytes memory init = abi.encodeWithSelector(
            USDa.initialize.selector,
            adminAddress,
            UNREAL_REBASE_MANAGER
        );

        usdaProxy = _deployProxy("USDa", address(usdaToken), init);
    }
}
