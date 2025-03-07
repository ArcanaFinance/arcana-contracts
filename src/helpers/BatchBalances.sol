// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BatchBalances
 * @notice Helper contract for fetching batch balances
 */
contract BatchBalances {

    struct AccountBalances {
        address account;
        uint256[] balances;
    }
    
    function getBalances(address token, address[] memory accounts) external view returns (uint256[] memory balances) {
        balances = new uint256[](accounts.length);

        IERC20 tokenContract = IERC20(token);
        
        for (uint256 i; i < accounts.length;) {
            balances[i] = tokenContract.balanceOf(accounts[i]);
            unchecked {
                ++i;
            }
        }

        return balances;
    }

    function getBalances(address[] memory tokens, address[] memory accounts) external view returns (AccountBalances[] memory balanceData) {
        balanceData = new AccountBalances[](accounts.length);
        
        for (uint256 i; i < accounts.length;) {
            balanceData[i].account = accounts[i];
            balanceData[i].balances = new uint256[](tokens.length);

            for (uint256 j; j < tokens.length;) {
                IERC20 tokenContract = IERC20(tokens[j]);
                balanceData[i].balances[j] = tokenContract.balanceOf(accounts[i]);

                unchecked {
                    ++j;
                }
            }

            unchecked {
                ++i;
            }
        }

        return balanceData;
    }

}
