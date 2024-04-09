// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title sDJUSD
 * @notice TODO
 * @dev TODO
 */
contract StakedDJUSD is ERC20Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable { // TODO: Create Interface

    // ~ Variables ~
    
    /// @dev TODO
    address public vault;

    /// @notice Zero address not allowed
    error ZeroAddressException();
    /// @notice Only the minter role can perform an action
    error OnlyVault();
    /// @notice Emitted when msg.sender is not authorized
    error NotAuthorized(address account);


    // ~ Constructor ~

    constructor() {
        _disableInitializers();
    }


    // ~ Initializer ~

    /**
     * @notice Initializes this contract.
     * @param _admin Initial owner address.
     * @param _admin Initial vault address.
     */
    function initialize(address _admin, address _vault) external initializer {
        if (_admin == address(0) || _vault == address(0)) revert ZeroAddressException();
        __Ownable2Step_init();
        __Ownable_init(_admin);
        vault = _vault;
    }

    // ~ External Methods ~

    /**
     * @notice Allows the `vault` to mint more DJUSD tokens to a specified `to` address.
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != vault) revert OnlyVault();
        _mint(to, amount);
    }

    /**
     * @notice Burns `amount` tokens from msg.sender.
     */
    function burn(uint256 amount) external virtual {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Burns `amount` of tokens from `account`, given approval from `account`.
     */
    function burnFrom(address account, uint256 amount) external virtual {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    
    // ~ Internal Methods ~

    /**
     * @notice Overriden from UUPSUpgradeable
     * @dev Restricts ability to upgrade contract to `DEFAULT_ADMIN_ROLE`
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
