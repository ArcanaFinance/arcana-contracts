// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ArcanaPointsToken
 * @notice Arcana Points Token Contract
 * @dev TODO
 */
contract ArcanaPointsToken is ERC20 {

    // ~ Constructor ~

    /**
     * @notice Initializes ArcanaPointsToken
     */
    constructor() ERC20("Arcana Points Token", "ARCANA") {}

    // TODO: Mint and Burn as owner
}