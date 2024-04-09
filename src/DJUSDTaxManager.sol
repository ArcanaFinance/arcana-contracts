// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { DJUSD } from "./DJUSD.sol";

/**
 * @title DJUSDTaxManager
 * @notice Tax Manager to DJUSD contract 
 * @dev This contract manages the taxation of rebases on the DJUSD token. This contract facilitates the rebase of DJUSD and
 *      during rebase, will calculate an amount of DJUSD to mint to the `feeCollector` and thus re-calculating the rebaseIndex to result in
 *      the targeted post-rebase totalSupply with the new minted tokens in mind.
 */
contract DJUSDTaxManager {

    /// @dev Stores the % of each rebase that is taxed.
    uint256 constant public taxRate = 0.10e18;
    /// @dev Stores the address in which newly minted tokens are sent to.
    address public feeCollector;
    /// @dev Stores the contract reference to DJUSD.
    DJUSD public djUsd;

    /// @notice Zero address not allowed
    error ZeroAddressException();

    /**
     * @notice Initializes DJUSDTaxManager.
     * @param _djusd Address of DJUSD contract.
     * @param _feeCollector Address of feeCollector.
     */
    constructor(address _djusd, address _feeCollector) {
        if (_djusd == address(0) || _feeCollector == address(0)) revert ZeroAddressException();
        djUsd = DJUSD(_djusd);
        feeCollector = _feeCollector;
    }

    /**
     * @notice This method facilitates the taxed rebase of DJUSD. It calculates the new total supply, given `nextIndex`. It then takes a tax by
     * minting a percentage of the total supply delta and then calculating a new rebaseIndex.
     * @param currentIndex The current rebaseIndex of DJUSD.
     * @param nextIndex The new rebaseIndex used to calculate the new total supply.
     */
    function collectOnRebase(uint256 currentIndex, uint256 nextIndex) external {
        require(msg.sender == address(djUsd), "NA");
        uint256 supply = djUsd.totalSupply();
        uint256 totalSupplyShares = (supply * 1e18) / currentIndex;
        uint256 newSupply = supply * nextIndex / currentIndex;
        uint256 mintAmount;
        if (newSupply > supply) {
            unchecked {
                uint256 delta = newSupply - supply;
                uint256 tax = delta * taxRate / 1e18;
                uint256 netIncrease = delta - tax;
                uint256 finalSupply = newSupply;

                newSupply = supply + netIncrease;
                mintAmount = finalSupply - newSupply;
                nextIndex = newSupply * 1e18 / totalSupplyShares;
            }
        }
        djUsd.setRebaseIndex(nextIndex, 1);
        if (mintAmount != 0) {
            djUsd.mint(feeCollector, mintAmount);
        }
    }
}