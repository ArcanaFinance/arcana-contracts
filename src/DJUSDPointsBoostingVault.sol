// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {IERC20 ,ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RebaseTokenMath} from "@tangible/contracts/libraries/RebaseTokenMath.sol";

import {DJUSD as DJUSDToken} from "./DJUSD.sol";

/**
 * @title djUSD Points Boost Vault
 * @dev This contract represents a points-based system for djUSD token holders. By depositing djUSD tokens, users
 * receive djPT tokens, which can be redeemed back to djUSD. This mechanism effectively disables rebase functionality
 * for djUSD within this system.
 * @author Caesar LaVey
 */
contract DJUSDPointsBoostVault is ERC20 {
    address public immutable DJUSD;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /**
     * @dev Sets the djUSD token address and disables its rebase functionality upon deployment.
     * @param djusd The address of the djUSD token.
     */
    constructor(address djusd) ERC20("djUSD Points Token", "djPT") {
        DJUSD = djusd;
        DJUSDToken(djusd).disableRebase(address(this), true);
    }

    /**
     * @notice Provides a preview of djPT shares for a given djUSD deposit.
     * @dev Guarantees a 1:1 exchange ratio for deposits, reflecting the contract's design where each djUSD deposited
     * is matched with an equivalent amount of djPT shares. This behavior is integral to the contract and not subject
     * to change based on external factors like rebasing.
     * @param assets The amount of djUSD to be deposited.
     * @return shares The equivalent amount of djPT shares, guaranteed to be a 1:1 match with the djUSD deposited.
     */
    function previewDeposit(address, uint256 assets) external pure returns (uint256 shares) {
        shares = assets;
    }

    /**
     * @notice Provides a preview of djUSD assets for a given amount of djPT shares to be redeemed.
     * @dev Accounts for the user's rebase opt-out status. If opted out, a 1:1 ratio is used. Otherwise, rebase
     * adjustments apply.
     * @param from The account whose opt-out status to check.
     * @param shares The amount of djPT shares to redeem.
     * @return assets The equivalent amount of djUSD assets.
     */
    function previewRedeem(address from, uint256 shares) external view returns (uint256 assets) {
        if (DJUSDToken(DJUSD).optedOut(from)) {
            assets = shares;
        } else {
            uint256 rebaseIndex = DJUSDToken(DJUSD).rebaseIndex();
            uint256 djusdShares = RebaseTokenMath.toShares(shares, rebaseIndex);
            assets = RebaseTokenMath.toTokens(djusdShares, rebaseIndex);
        }
    }

    /**
     * @notice Deposits djUSD tokens into the vault in exchange for djPT tokens.
     * @dev Mints djPT tokens to the recipient equivalent to the amount of djUSD tokens deposited.
     * @param assets The amount of djUSD tokens to deposit.
     * @param recipient The address to receive the djPT tokens.
     * @return shares The amount of djPT tokens minted.
     */
    function deposit(uint256 assets, address recipient) external returns (uint256 shares) {
        shares = _pullDJUSD(msg.sender, assets);
        _mint(recipient, shares);
        emit Deposit(msg.sender, recipient, assets, shares);
    }

    /**
     * @notice Redeems djPT tokens in exchange for djUSD tokens.
     * @dev Burns the djPT tokens from the sender and returns the equivalent amount of djUSD tokens.
     * @param shares The amount of djPT tokens to redeem.
     * @param recipient The address to receive the djUSD tokens.
     * @return assets The amount of djUSD tokens returned.
     */
    function redeem(uint256 shares, address recipient) external returns (uint256 assets) {
        _burn(msg.sender, shares);
        assets = _pushDJUSD(recipient, shares);
        emit Withdraw(msg.sender, recipient, msg.sender, assets, shares);
    }

    /**
     * @dev Pulls djUSD tokens from the sender to this contract.
     * @param from The address from which djUSD tokens are transferred.
     * @param amount The amount of djUSD tokens to transfer.
     * @return The amount of djUSD tokens successfully transferred.
     */
    function _pullDJUSD(address from, uint256 amount) internal returns (uint256) {
        IERC20 token = IERC20(DJUSD);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(from, address(this), amount);
        return token.balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @dev Pushes djUSD tokens from this contract to the recipient.
     * @param to The address to which djUSD tokens are transferred.
     * @param amount The amount of djUSD tokens to transfer.
     * @return The amount of djUSD tokens successfully transferred.
     */
    function _pushDJUSD(address to, uint256 amount) internal returns (uint256) {
        IERC20 token = IERC20(DJUSD);
        uint256 balanceBefore = token.balanceOf(to);
        token.transfer(to, amount);
        return token.balanceOf(to) - balanceBefore;
    }
}
