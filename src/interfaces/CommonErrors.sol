// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

/**
 * @title Common Error Definitions
 * @author Caesar LaVey
 * @dev Interface encapsulating common error patterns for reusability across contracts. This approach centralizes error
 * handling, facilitating maintenance and understanding of error causes.
 */
interface CommonErrors {
    /**
     * @dev Emitted when an operation involves an item that already exists in a set or list, where uniqueness is
     * required.
     * @param item The address of the item that was attempted to be added or modified but already exists.
     */
    error AlreadyExists(address item);

    /**
     * @dev Emitted when a request cannot be fulfilled due to insufficient resources or funds.
     * @param requested The amount requested for the operation.
     * @param available The amount currently available, which is less than the requested amount.
     */
    error InsufficientFunds(uint256 requested, uint256 available);

    /**
     * @dev Emitted when an operation involves the zero address, where a valid address is required.
     */
    error InvalidZeroAddress();

    /**
     * @dev Emitted when an operation involves an invalid address, where a valid address is required.
     */
    error InvalidAddress(address address_);

    /**
     * @dev Emitted when an operation results in no change to the value or state, where a change was expected.
     */
    error ValueUnchanged();
}
