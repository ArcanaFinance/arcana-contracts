// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

interface IarcUSDDefinitions {
    // ~ Events ~

    /// @notice This event is fired when the minter changes.
    event MinterUpdated(address indexed newMinter, address indexed oldMinter);
    /// @notice This event is emitted when the rebase manager is updated.
    event RebaseIndexManagerUpdated(address indexed manager);
    /// @notice This event is emitted when the address of taxManager is updated.
    event TaxManagerUpdated(address indexed newTaxManager);
    /// @notice This event is emitted when the supply limit is updated.
    event SupplyLimitUpdated(uint256 indexed newSupplyLimit);

    // ~ Errors ~

    /// @notice Error emitted when totalSupply exceeds `supplyLimit`.
    error SupplyLimitExceeded();
    /// @notice Zero address not allowed.
    error ZeroAddressException();
    /// @notice It's not possible to renounce the ownership.
    error CantRenounceOwnership();
    /// @notice Only the minter role can perform an action.
    error OnlyMinter();
    /// @notice Emitted when msg.sender is not authorized.
    error NotAuthorized(address account);
    /// @notice Emitted when the new rebaseIndex is being set to 0.
    error ZeroRebaseIndex();
    /// @notice Emitted when a new rebaseIndex is not greater than the current rebaseIndex.
    error InvalidRebaseIndex();
}
