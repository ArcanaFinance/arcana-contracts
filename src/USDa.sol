// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

// local interfaces
import {ITaxManager} from "./interfaces/ITaxManager.sol";
import {IUSDaDefinitions} from "./interfaces/IUSDaDefinitions.sol";

// local imports
import {LayerZeroRebaseTokenUpgradeable} from "@tangible/contracts/tokens/LayerZeroRebaseTokenUpgradeable.sol";
import {CrossChainToken} from "@tangible/contracts/tokens/CrossChainToken.sol";

/**
 * @title USDa
 * @notice USDa Stable Coin Contract
 * @dev This contract extends the functionality of `LayerZeroRebaseTokenUpgradeable` to support rebasing and cross-chain
 * bridging of this token.
 */
contract USDa is LayerZeroRebaseTokenUpgradeable, UUPSUpgradeable, IUSDaDefinitions {
    // ~ Variables ~

    /// @dev Stores the address of the `USDaMinter` contract.
    address public minter;
    /// @dev Stores the address of the Rebase Manager which calls `setRebaseIndex`.
    address public rebaseManager;
    /// @dev Stores the total supply limit. Total Supply cannot exceed this amount.
    uint256 public supplyLimit;
    /// @dev Stores USDaTaxManager contract address.
    address public taxManager;

    // ~ Constructor ~

    /**
     * @param mainChainId The chain ID that represents the main chain.
     * @param endpoint The Layer Zero endpoint for cross-chain operations.
     */
    constructor(uint256 mainChainId, address endpoint)
        CrossChainToken(mainChainId)
        LayerZeroRebaseTokenUpgradeable(endpoint)
    {
        _disableInitializers();
    }

    // ~ Initializer ~

    /**
     * @notice Initializes this contract.
     * @param _admin Initial owner address.
     * @param _rebaseManager Address in charge of managing updates to `rebaseIndex`.
     */
    function initialize(address _admin, address _rebaseManager) external initializer {
        if (_admin == address(0)) revert ZeroAddressException();
        if (_rebaseManager == address(0)) revert ZeroAddressException();

        __LayerZeroRebaseToken_init(_admin, "USDa", "USDa");
        _setRebaseIndex(1 ether, 1);
        rebaseManager = _rebaseManager;
    }

    // ~ External Methods ~

    /**
     * @notice This method allows the rebaseManager to set the rebaseIndex.
     * @param newIndex The new rebaseIndex.
     */
    function setRebaseIndex(uint256 newIndex, uint256 nonce) external {
        if (msg.sender != rebaseManager && msg.sender != taxManager) revert NotAuthorized(msg.sender);
        if (newIndex == 0) revert ZeroRebaseIndex();
        uint256 currentIndex = rebaseIndex();

        if (taxManager == address(0) || msg.sender == taxManager) {
            _setRebaseIndex(newIndex, nonce);
        } else {
            ITaxManager(taxManager).collectOnRebase(currentIndex, newIndex, nonce);
        }
    }

    /**
     * @notice This method disables rebaseIndex multiplier for a given address.
     * @param account Account not affected by rebase.
     * @param isDisabled If true, balanceOf(`account`) will not be affected by rebase.
     */
    function disableRebase(address account, bool isDisabled) external {
        if (msg.sender != account && msg.sender != rebaseManager) revert NotAuthorized(msg.sender);
        require(_isRebaseDisabled(account) != isDisabled, "value already set");
        _disableRebase(account, isDisabled);
    }

    /**
     * @notice Allows owner to set a ceiling on USDa total supply to throttle minting.
     */
    function setSupplyLimit(uint256 limit) external onlyOwner {
        require(limit >= totalSupply(), "Cannot set limit less than totalSupply");
        emit SupplyLimitUpdated(limit);
        supplyLimit = limit;
    }

    /**
     * @notice Allows owner to set the new taxManager.
     */
    function setTaxManager(address newTaxManager) external onlyOwner {
        if (newTaxManager == address(0)) revert ZeroAddressException();
        emit TaxManagerUpdated(newTaxManager);
        taxManager = newTaxManager;
    }

    /**
     * @notice Allows the owner to update the `rebaseManager` state variable.
     */
    function setRebaseManager(address newRebaseManager) external onlyOwner {
        if (newRebaseManager == address(0)) revert ZeroAddressException();
        emit RebaseIndexManagerUpdated(newRebaseManager);
        rebaseManager = newRebaseManager;
    }

    /**
     * @notice Allows the owner to update the `minter` state variable.
     */
    function setMinter(address newMinter) external onlyOwner {
        emit MinterUpdated(newMinter, minter);
        minter = newMinter;
    }

    /**
     * @notice Allows the `minter` to mint more USDa tokens to a specified `to` address.
     */
    function mint(address to, uint256 amount) external {
        if (msg.sender != minter && msg.sender != taxManager) revert OnlyMinter();
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

    /**
     * @notice Returns the amount of USDa is held by addresses that are opted out of rebase.
     */
    function optedOutTotalSupply() external view returns (uint256) {
        return ERC20Upgradeable.totalSupply();
    }

    /**
     * @dev Ownership cannot be renounced.
     */
    function renounceOwnership() public view override onlyOwner {
        revert CantRenounceOwnership();
    }

    // ~ Internal Methods ~

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (totalSupply() >= supplyLimit) revert SupplyLimitExceeded();
    }

    /**
     * @notice Overriden from UUPSUpgradeable
     * @dev Restricts ability to upgrade contract to owner
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
