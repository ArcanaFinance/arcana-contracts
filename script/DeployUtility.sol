// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC1967Utils, ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title DeployUtility
 * @notice This contract will act as a base contract for script deployments. It will include utility methods for
 * assisting in
 * the reading/writing of JSON files stored locally to track latest deployment addresses.
 * @dev This contract was forked from SeaZarrgh's stack deployment base contracts.
 */
abstract contract DeployUtility is Script {
    string private chainAlias;

    function _setUp(string memory _alias) internal {
        chainAlias = _alias;
    }

    /**
     * @dev Saves the deployment address of a contract to the chain's deployment address JSON file. This function is
     * essential for tracking the deployment of contracts and ensuring that the contract's address is stored for future
     * reference.
     * @param name The name of the contract for which the deployment address is being saved.
     * @param addr The address of the deployed contract.
     */
    function _saveDeploymentAddress(string memory name, address addr) internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/", chainAlias, ".json");
        string memory json;
        string memory output;
        string[] memory keys;

        if (vm.exists(path)) {
            json = vm.readFile(path);
            keys = vm.parseJsonKeys(json, "$");
        } else {
            keys = new string[](0);
        }

        bool serialized;

        for (uint256 i; i < keys.length; i++) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(name))) {
                output = vm.serializeAddress(chainAlias, name, addr);
                serialized = true;
            } else {
                address value = vm.parseJsonAddress(json, string.concat(".", keys[i]));
                output = vm.serializeAddress(chainAlias, keys[i], value);
            }
        }

        if (!serialized) {
            output = vm.serializeAddress(chainAlias, name, addr);
        }

        vm.writeJson(output, path);
    }

    /**
     * @dev Loads the deployment address of a contract from the chain's deployment address JSON file. This function is
     * crucial for retrieving the address of a previously deployed contract, particularly when the address is needed for
     * subsequent operations, like proxy upgrades.
     * @param name The name of the contract for which the deployment address is being loaded.
     * @return addr The address of the deployed contract.
     */
    function _loadDeploymentAddress(string memory name) internal returns (address) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/", chainAlias, ".json");

        if (vm.exists(path)) {
            string memory json = vm.readFile(path);
            string[] memory keys = vm.parseJsonKeys(json, "$");
            for (uint256 i; i < keys.length; i++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes(name))) {
                    return vm.parseJsonAddress(json, string.concat(".", keys[i]));
                }
            }
        }

        return address(0);
    }
}
