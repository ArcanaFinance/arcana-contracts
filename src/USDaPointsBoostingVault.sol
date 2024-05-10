// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RebaseTokenMath} from "@tangible/contracts/libraries/RebaseTokenMath.sol";

import {USDa as USDaToken} from "./USDa.sol";

/**
 * @title USDa Points Boost Vault
 * @dev This contract represents a points-based system for USDa token holders. By depositing USDa tokens, users
 * receive PTa tokens, which can be redeemed back to USDa. This mechanism effectively disables rebase functionality
 * for USDa within this system.
 * @author Caesar LaVey
 */
contract USDaPointsBoostVault is ERC20, Ownable {
    address public immutable USDa;
    bool public stakingEnabled;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    error StakingDisabled();
    error AlreadySet(bool value);

    modifier isEnabled() {
        if (!stakingEnabled) revert StakingDisabled();
        _;
    }

    /**
     * @dev Sets the USDa token address and disables its rebase functionality upon deployment.
     * @param usda The address of the USDa token.
     */
    constructor(address admin, address usda) ERC20("USDa Points Token", "PTa") Ownable(admin) {
        USDa = usda;
        USDaToken(usda).disableRebase(address(this), true);
        _mint(address(this), type(uint256).max);
        stakingEnabled = true;
    }

    /**
     * @notice Allows the owner to store a boolean value in `stakingEnabled`. 
     * @dev If `stakingEnabled` is true, users can call deposit and redeem. If false, these methods are locked.
     * This method is mainly needed during rebase calculations of USDa.
     * @param _isEnabled If true, deposit and redeem will be locked.
     */
    function setStakingEnabled(bool _isEnabled) external onlyOwner {
        if (stakingEnabled == _isEnabled) revert AlreadySet(_isEnabled);
        stakingEnabled = _isEnabled;
    }

    /**
     * @notice Deposits USDa tokens into the vault in exchange for PTa tokens.
     * @dev Mints PTa tokens to the recipient equivalent to the amount of USDa tokens deposited.
     * @param assets The amount of USDa tokens to deposit.
     * @param recipient The address to receive the PTa tokens.
     * @return shares The amount of PTa tokens minted.
     */
    function deposit(uint256 assets, address recipient) external isEnabled returns (uint256 shares) {
        shares = _pullUSDa(msg.sender, assets);
        _transfer(address(this), recipient, shares);
        emit Deposit(msg.sender, recipient, assets, shares);
    }

    /**
     * @notice Redeems PTa tokens in exchange for USDa tokens.
     * @dev Burns the PTa tokens from the sender and returns the equivalent amount of USDa tokens.
     * @param shares The amount of PTa tokens to redeem.
     * @param recipient The address to receive the USDa tokens.
     * @return assets The amount of USDa tokens returned.
     */
    function redeem(uint256 shares, address recipient) external isEnabled returns (uint256 assets) {
        _transfer(msg.sender, address(this), shares);
        assets = _pushUSDa(recipient, shares);
        emit Withdraw(msg.sender, recipient, msg.sender, assets, shares);
    }

    /**
     * @notice Provides a preview of PTa shares for a given USDa deposit.
     * @dev Guarantees a 1:1 exchange ratio for deposits, reflecting the contract's design where each USDa deposited
     * is matched with an equivalent amount of PTa shares. This behavior is integral to the contract and not subject
     * to change based on external factors like rebasing.
     * @param assets The amount of USDa to be deposited.
     * @return shares The equivalent amount of PTa shares, guaranteed to be a 1:1 match with the USDa deposited.
     */
    function previewDeposit(address, uint256 assets) external pure returns (uint256 shares) {
        shares = assets;
    }

    /**
     * @notice Provides a preview of USDa assets for a given amount of PTa shares to be redeemed.
     * @dev Accounts for the user's rebase opt-out status. If opted out, a 1:1 ratio is used. Otherwise, rebase
     * adjustments apply.
     * @param from The account whose opt-out status to check.
     * @param shares The amount of PTa shares to redeem.
     * @return assets The equivalent amount of USDa assets.
     */
    function previewRedeem(address from, uint256 shares) external view returns (uint256 assets) {
        if (USDaToken(USDa).optedOut(from)) {
            assets = shares;
        } else {
            uint256 rebaseIndex = USDaToken(USDa).rebaseIndex();
            uint256 usdaShares = RebaseTokenMath.toShares(shares, rebaseIndex);
            assets = RebaseTokenMath.toTokens(usdaShares, rebaseIndex);
        }
    }

    /**
     * @dev Pulls USDa tokens from the sender to this contract.
     * @param from The address from which USDa tokens are transferred.
     * @param amount The amount of USDa tokens to transfer.
     * @return The amount of USDa tokens successfully transferred.
     */
    function _pullUSDa(address from, uint256 amount) internal returns (uint256) {
        IERC20 token = IERC20(USDa);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(from, address(this), amount);
        return token.balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @dev Pushes USDa tokens from this contract to the recipient.
     * @param to The address to which USDa tokens are transferred.
     * @param amount The amount of USDa tokens to transfer.
     * @return The amount of USDa tokens successfully transferred.
     */
    function _pushUSDa(address to, uint256 amount) internal returns (uint256) {
        IERC20 token = IERC20(USDa);
        uint256 balanceBefore = token.balanceOf(to);
        token.transfer(to, amount);
        return token.balanceOf(to) - balanceBefore;
    }
}
