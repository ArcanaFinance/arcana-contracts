// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// lz imports
import {ICommonOFT} from "@layerzerolabs/contracts/token/oft/v2/interfaces/ICommonOFT.sol";
import {IOFTV2} from "@layerzerolabs/contracts/token/oft/v2/interfaces/IOFTV2.sol";

// local imports
import {arcUSDMinter} from "./arcUSDMinter.sol";
import {CommonValidations} from "./libraries/CommonValidations.sol";

/**
 * @title CustodianManager
 * @notice Custodian contract for arcUSDMinting.
 * @dev This contract will withdraw from the arcUSDMinter contract and transfer collateral to the multisig custodian.
 */
contract CustodianManager is OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using CommonValidations for *;

    /// @dev Stores the contact reference to the arcUSDMinter contract.
    arcUSDMinter public immutable arcMinter;
    /// @dev Stores contract address to custodian where collateral is transferred.
    address public custodian;
    /// @dev Stores the task address which allows for the withdrawal of funds from the arcMinter contract.
    address public task;

    event FundsWithdrawn(address asset, uint256 amount);
    event FundsSentToCustodian(address custodian, address asset, uint256 amount);
    event CustodianUpdated(address indexed custodian);
    event TaskAddressUpdated(address indexed task);

    error InsufficientBalance(uint256 expected, uint256 actual);
    error NoFundsWithdrawable();
    error NotAuthorized(address caller);

    /// @dev Used to sanitize a caller address to ensure msg.sender is equal to task address or owner.
    modifier onlyTask() {
        if (msg.sender != task && msg.sender != owner()) revert NotAuthorized(msg.sender);
        _;
    }

    /**
     * @notice Initializes CustodianManager.
     * @param _arcMinter Contract address for arcUSDMinter.
     */
    constructor(address _arcMinter) {
        _arcMinter.requireNonZeroAddress();
        arcMinter = arcUSDMinter(_arcMinter);
    }

    /**
     * @notice Initializes contract from the proxy.
     * @param initialOwner Initial owner address for this contract.
     * @param initialCustodian Initial custodian address.
     */
    function initialize(address initialOwner, address initialCustodian) public initializer {
        initialOwner.requireNonZeroAddress();
        initialCustodian.requireNonZeroAddress();

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        custodian = initialCustodian;
    }

    /**
     * @notice This method will withdraw assets from the arcMinter contract and transfer it to the custodian address.
     * @param asset ERC-20 asset being withdrawn from the arcMinter.
     * @param amount Amount of asset to withdraw. Must be greater than 0 but less than or equal to withdrawable().
     * @custom:error NotAuthorized Thrown if caller is not equal to ask address or owner.
     * @custom:error NoFundsWithdrawable Thrown if there are no funds to be withdrawn or amount exceeds withdrawable.
     * @custom:error InsufficientBalance Thrown if the amount being withdrawn is greater than withdrawable.
     * @custom:event FundsSentToCustodian Amount of asset transferred to what custodian.
     */
    function withdrawFunds(address asset, uint256 amount) external onlyTask {
        uint256 amountWithdrawable = withdrawable(asset);
        if (amountWithdrawable == 0) revert NoFundsWithdrawable();
        if (amount > amountWithdrawable) revert InsufficientBalance(amount, amountWithdrawable);

        // withdraw from arcUSDMinter
        uint256 received = _withdrawAssets(asset, amount);
        // transfer to custodian
        IERC20(asset).safeTransfer(custodian, received);  

        emit FundsSentToCustodian(custodian, asset, received);
    }

    /**
     * @notice This method allows the owner to update the custodian address.
     * @dev The custodian address will receive any assets withdrawn from the arcMinter contract.
     * @param newCustodian New custodian address.
     * @custom:error InvalidZeroAddress Thrown if newCustodian is equal to address(0).
     * @custom:error ValueUnchanged Thrown if the custodian is already set to newCustodian.
     */
    function updateCustodian(address newCustodian) external onlyOwner {
        newCustodian.requireNonZeroAddress();
        custodian.requireDifferentAddress(newCustodian);
        custodian = newCustodian;
        emit CustodianUpdated(newCustodian);
    }

    /**
     * @notice This method allows the owner to update the task address.
     * @dev The task address allows us to assign a gelato task to be able to call the withdraw method.
     * @param newTask New task address.
     * @custom:error InvalidZeroAddress Thrown if newTask is equal to address(0).
     * @custom:error ValueUnchanged Thrown if the task is already set to newTask.
     */
    function updateTaskAddress(address newTask) external onlyOwner {
        newTask.requireNonZeroAddress();
        task.requireDifferentAddress(newTask);
        task = newTask;
        emit TaskAddressUpdated(newTask);
    }

    /**
     * @notice This view method returns the amount of assets that can be withdrawn from the arcMinter contract.
     * @dev This method takes into account the amount of tokens the arcMinter contract needs to fulfill pending claims
     * and therefore is subtracted from the what is withdrawable from the balance. If the amount of required tokens
     * (to fulfill pending claims) is greater than the balance, withdrawable will return 0.
     * @param asset ERC-20 asset we wish to query withdrawable.
     * @return Amount of asset that can be withdrawn from the arcMinter contract.
     */
    function withdrawable(address asset) public view returns (uint256) {
        uint256 required = arcMinter.getPendingClaims(asset);
        uint256 balance = IERC20(asset).balanceOf(address(arcMinter));

        if (balance > required) {
            unchecked {
                return balance - required;
            }
        }
        else {
            return 0;
        }
    }

    /**
     * @dev Withdraws a specified amount of a supported asset from a the Minter contract to this contract, adjusted
     * based on the redemption requirements. We assess the contract's balance before the withdraw and after the withdraw
     * to ensure the proper amount of tokens received is accounted for. This comes in handy in the event a rebase rounding error
     * results in a slight deviation between amount withdrawn and the amount received.
     * @param asset The address of the supported asset to be withdrawn.
     * @param amount The intended amount of the asset to transfer from the user. The function calculates the actual
     * transfer based on the asset’s pending redemption needs.
     * @return received The actual amount of the asset received to this contract, which may differ from
     * the intended amount due to transaction fees.
     * @custom:event CustodyTransfer Logs the transfer of the asset to this contract, detailing the amount and involved
     * parties.
     */
    function _withdrawAssets(address asset, uint256 amount) internal returns (uint256 received) {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        arcMinter.withdrawFunds(asset, amount);
        received = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        emit FundsWithdrawn(asset, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
