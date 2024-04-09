// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// lz imports
import { ILayerZeroUserApplicationConfig } from "@layerzerolabs/contracts/lzApp/interfaces/ILayerZeroUserApplicationConfig.sol";

// local interfaces
import { ITaxManager } from "./interfaces/ITaxManager.sol";
import { IDJUSDDefinitions } from "./interfaces/IDJUSDDefinitions.sol";

// local imports
import { LayerZeroRebaseTokenUpgradeable } from "./utils/LayerZeroRebaseTokenUpgradeable.sol";
import { CrossChainToken } from "./utils/CrossChainToken.sol";

/**
 * @title DJUSD
 * @notice DJUSD Stable Coin Contract
 * @dev This contract extends the functionality of `LayerZeroRebaseTokenUpgradeable` to support rebasing and cross-chain bridging of this token.
 */
contract DJUSD is LayerZeroRebaseTokenUpgradeable, UUPSUpgradeable, Ownable2StepUpgradeable, IDJUSDDefinitions, ILayerZeroUserApplicationConfig {

    // ~ Variables ~
    
    /// @dev Stores the address of the `DJUSDMinting` contract.
    address public minter;
    /// @dev Stores the address of the Rebase Manager which calls `setRebaseIndex`.
    address public rebaseManager;
    /// @dev Stores the total supply limit. Total Supply cannot exceed this amount.
    uint256 public supplyLimit;
    /// @dev Stores DJUSDTaxManager contract address.
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

        __LayerZeroRebaseToken_init("DJUSD", "DJUSD");
        __Ownable2Step_init();
        __Ownable_init(_admin);
    
        _setRebaseIndex(1 ether, 1);
        rebaseManager = _rebaseManager;
    }


    // ~ External Methods ~

    function setRebaseIndex(uint256 newIndex, uint256 nonce) external {
        if (msg.sender != rebaseManager && msg.sender != taxManager) revert NotAuthorized(msg.sender);
        uint256 currentIndex = rebaseIndex();

        if (taxManager == address(0) || msg.sender == taxManager) {
            _setRebaseIndex(newIndex, nonce);
        } else {
            ITaxManager(taxManager).collectOnRebase(currentIndex, newIndex);
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
     * @notice Allows owner to set a ceiling on DJUSD total supply to throttle minting.
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
     * @notice Allows the `minter` to mint more DJUSD tokens to a specified `to` address.
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
     * @dev Sets the configuration of the LayerZero user application for a given version, chain ID, and config type.
     *
     * Requirements:
     * - Only the owner can set the configuration.
     *
     * @param version The version for which the configuration is to be set.
     * @param chainId The ID of the chain for which the configuration is being set.
     * @param configType The type of the configuration to be set.
     * @param config The actual configuration data in bytes format.
     */
    function setConfig(uint16 version, uint16 chainId, uint256 configType, bytes calldata config) external override onlyOwner {
        _setConfig(version, chainId, configType, config);
    }

    /**
     * @dev Sets the version to be used for sending LayerZero messages.
     *
     * Requirements:
     * - Only the owner can set the send version.
     *
     * @param version The version to be set for sending messages.
     */
    function setSendVersion(uint16 version) external override onlyOwner {
        _setSendVersion(version);
    }

    /**
     * @dev Sets the version to be used for receiving LayerZero messages.
     *
     * Requirements:
     * - Only the owner can set the receive version.
     *
     * @param version The version to be set for receiving messages.
     */
    function setReceiveVersion(uint16 version) external override onlyOwner {
        _setReceiveVersion(version);
    }

    /**
     * @dev Resumes the reception of LayerZero messages from a specific source chain and address.
     *
     * Requirements:
     * - Only the owner can force the resumption of message reception.
     *
     * @param srcChainId The ID of the source chain from which message reception is to be resumed.
     * @param srcAddress The address on the source chain for which message reception is to be resumed.
     */
    function forceResumeReceive(uint16 srcChainId, bytes calldata srcAddress) external override onlyOwner {
        _forceResumeReceive(srcChainId, srcAddress);
    }

    /**
     * @dev Sets the trusted path for cross-chain communication with a specified remote chain.
     *
     * Requirements:
     * - Only the owner can set the trusted path.
     *
     * @param remoteChainId The ID of the remote chain for which the trusted path is being set.
     * @param path The trusted path encoded as bytes.
     */
    function setTrustedRemote(uint16 remoteChainId, bytes calldata path) external onlyOwner {
        _setTrustedRemote(remoteChainId, path);
    }

    /**
     * @dev Sets the trusted remote address for cross-chain communication with a specified remote chain.
     * The function also automatically appends the contract's own address to the path.
     *
     * Requirements:
     * - Only the owner can set the trusted remote address.
     *
     * @param remoteChainId The ID of the remote chain for which the trusted address is being set.
     * @param remoteAddress The trusted remote address encoded as bytes.
     */
    function setTrustedRemoteAddress(uint16 remoteChainId, bytes calldata remoteAddress) external onlyOwner {
        _setTrustedRemoteAddress(remoteChainId, remoteAddress);
    }

    /**
     * @dev Sets the "Precrime" address, which could be an address for handling fraudulent activities or other specific
     * behaviors.
     *
     * Requirements:
     * - Only the owner can set the Precrime address.
     *
     * @param _precrime The address to be set as Precrime.
     */
    function setPrecrime(address _precrime) external onlyOwner {
        _setPrecrime(_precrime);
    }

    /**
     * @dev Sets the minimum required gas for a specific packet type and destination chain.
     *
     * Requirements:
     * - Only the owner can set the minimum destination gas.
     *
     * @param dstChainId The ID of the destination chain for which the minimum gas is being set.
     * @param packetType The type of the packet for which the minimum gas is being set.
     * @param minGas The minimum required gas in units.
     */
    function setMinDstGas(uint16 dstChainId, uint16 packetType, uint256 minGas) external onlyOwner {
        _setMinDstGas(dstChainId, packetType, minGas);
    }

    /**
     * @dev Sets the payload size limit for a specific destination chain.
     *
     * Requirements:
     * - Only the owner can set the payload size limit.
     *
     * @param dstChainId The ID of the destination chain for which the payload size limit is being set.
     * @param size The size limit in bytes.
     */
    function setPayloadSizeLimit(uint16 dstChainId, uint256 size) external onlyOwner {
        _setPayloadSizeLimit(dstChainId, size);
    }

    /**
     * @dev Toggles the use of custom adapter parameters.
     * When enabled, the contract will check gas limits based on the provided adapter parameters.
     *
     * @param useCustomAdapterParams Flag indicating whether to use custom adapter parameters.
     */
    function setUseCustomAdapterParams(bool useCustomAdapterParams) public virtual onlyOwner {
        _setUseCustomAdapterParams(useCustomAdapterParams);
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
     * @dev Restricts ability to upgrade contract to `DEFAULT_ADMIN_ROLE`
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
