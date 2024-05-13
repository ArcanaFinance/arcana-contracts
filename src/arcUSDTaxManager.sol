// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {arcUSD as arcUSDToken} from "./arcUSD.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title arcUSDTaxManager
 * @notice Tax Manager to arcUSD contract
 * @dev This contract manages the taxation of rebases on the arcUSD token. This contract facilitates the rebase of arcUSD
 * and during rebase, will calculate an amount of arcUSD to mint to the `feeCollector` and thus re-calculating the
 * rebaseIndex to result in the targeted post-rebase totalSupply with the new minted tokens in mind.
 */
contract arcUSDTaxManager is Ownable {
    /// @dev Stores the contract reference to arcUSD.
    arcUSDToken public immutable arcUSD;
    /// @dev Stores the % of each rebase that is taxed.
    uint256 public taxRate = 0.1e18;
    /// @dev Stores the address in which newly minted tokens are sent to.
    address public feeCollector;

    /// @dev Emitted when `taxRate` is updated.
    event TaxRateUpdated(uint256 taxRate);
    /// @dev Emitted when `feeCollector` is updated.
    event FeeCollectorUpdated(address feeCollector);

    /// @dev Zero address not allowed
    error ZeroAddressException();

    /**
     * @notice Initializes arcUSDTaxManager.
     * @param _admin Initial owner address.
     * @param _arcUSD Address of arcUSD contract.
     * @param _feeCollector Address of feeCollector.
     */
    constructor(address _admin, address _arcUSD, address _feeCollector) Ownable(_admin) {
        if (_arcUSD == address(0) || _feeCollector == address(0)) revert ZeroAddressException();
        arcUSD = arcUSDToken(_arcUSD);
        feeCollector = _feeCollector;
    }

    /**
     * @notice This method facilitates the taxed rebase of arcUSD. It calculates the new total supply, given `nextIndex`.
     * It then takes a tax by
     * minting a percentage of the total supply delta and then calculating a new rebaseIndex.
     * @dev This method does not take into account the amount of tokens that are opted out of rebse. It will calculate
     * the total Supply delta by only referencing the rebase supply which is directly affected by the new rebaseIndex.
     * @param currentIndex The current rebaseIndex of arcUSD.
     * @param nextIndex The new rebaseIndex used to calculate the new total supply.
     */
    function collectOnRebase(uint256 currentIndex, uint256 nextIndex, uint256 nonce) external {
        require(msg.sender == address(arcUSD), "NA");
        uint256 supply = arcUSD.totalSupply() - arcUSD.optedOutTotalSupply();
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
        arcUSD.setRebaseIndex(nextIndex, nonce);
        if (mintAmount != 0) {
            arcUSD.mint(feeCollector, mintAmount);
        }
    }

    /**
     * @notice Permissioned method for setting the `taxRate` var.
     */
    function setTaxRate(uint256 newTaxRate) external onlyOwner {
        require(newTaxRate < 1e18, "Tax cannot be 100%");
        emit TaxRateUpdated(newTaxRate);
        taxRate = newTaxRate;
    }

    /**
     * @notice Permissioned method for setting the `feeCollector` var.
     */
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert ZeroAddressException();
        emit FeeCollectorUpdated(newFeeCollector);
        feeCollector = newFeeCollector;
    }
}
