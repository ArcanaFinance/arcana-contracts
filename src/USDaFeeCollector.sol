// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title USDaFeeCollector
 * @notice This contract receives USDa from rebase fees and distributes them to the necessary addresses.
 */
contract USDaFeeCollector is Ownable {
    /// @dev Stores contract address of USDa token.
    address public immutable USDa;
    /// @dev Stores addresses where USDa rewards are distributed to.
    address[] public distributors;
    /// @dev Stores ratios of amount of USDa that's allocated to each address in `distributors`.
    uint256[] public ratios;

    /// @dev This event is emitted when USDa is transferred to a distributor as a reward.
    event RewardsDistributed(address receiver, uint256 amount);
    /// @dev This event is emitted when `updateRewardDistribution` is executed successfully.
    event DistributionUpdated(address[] newDistributors, uint256[] ratios);

    /// @dev Zero address not allowed.
    error ZeroAddressException();
    /// @dev If input arrays are size 0 or do not match, revert.
    error InvalidArraySize();

    /**
     * @notice Initializes USDaFeeCollector.
     * @param _admin Initial Owner of contract.
     * @param _usda Address of USDa contract.
     * @param _distributors Array of addresses that will receive USDa royalties.
     * @param _ratios Array of ratios for calculating percentage of royalties go to each distributor.
     */
    constructor(address _admin, address _usda, address[] memory _distributors, uint256[] memory _ratios)
        Ownable(_admin)
    {
        if (_usda == address(0) || _admin == address(0)) revert ZeroAddressException();

        uint256 len = _distributors.length;
        if (len != _ratios.length || len == 0) revert InvalidArraySize();

        USDa = _usda;
        distributors = _distributors;
        ratios = _ratios;
    }

    /**
     * @notice This method is used to distribute USDa rewards form this contract to the various addresses
     * stored in the `distributors` array.
     */
    function distributeUSDa() external {
        uint256 contractBalance = getUsdaBalance();
        uint256 len = distributors.length;
        uint256 totalRatio;

        for (uint256 i; i < len;) {
            totalRatio += ratios[i];
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < len;) {
            address receiver = distributors[i];
            uint256 amountToTransfer = (contractBalance * ratios[i]) / totalRatio;

            IERC20(USDa).transfer(receiver, amountToTransfer);
            emit RewardsDistributed(receiver, amountToTransfer);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Permissioned method for updating the reward distributions.
     * @param _distributors Array of addresses that will receive USDa rewards from this contract upon distribution.
     * @param _ratios Array of ratios of amount of rewards to send to each address in `_distributors`.
     */
    function updateRewardDistribution(address[] memory _distributors, uint256[] memory _ratios) external onlyOwner {
        uint256 len = _distributors.length;
        if (len != _ratios.length || len == 0) revert InvalidArraySize();

        emit DistributionUpdated(_distributors, _ratios);

        distributors = _distributors;
        ratios = _ratios;
    }

    /**
     * @notice View method for returning all addresses in `distributors`
     */
    function getDistributors() external view returns (address[] memory) {
        return distributors;
    }

    /**
     * @notice View method for returning all ratios in `ratios`
     */
    function getRatios() external view returns (uint256[] memory) {
        return ratios;
    }

    /**
     * @notice Returns the contract's balance of USDa token.
     */
    function getUsdaBalance() public view returns (uint256) {
        return IERC20(USDa).balanceOf(address(this));
    }
}
