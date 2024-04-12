// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// interfaces
import {CommonErrors} from "./interfaces/CommonErrors.sol";
import {IDJUSD} from "./interfaces/IDJUSD.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

// libs
import {CommonValidations} from "./libraries/CommonValidations.sol";

/**
 * @title DJUSD Minter
 * @author Caesar LaVey
 *
 * @notice DJUSDMinter facilitates the minting and redemption process of DJUSD tokens against various supported assets.
 * It allows for adding and removing assets and custodians, minting DJUSD by depositing assets, and requesting
 * redemption of DJUSD for assets. The contract uses a delay mechanism for redemptions to enhance security and manages
 * custody transfers of assets to designated custodians.
 *
 * @dev The contract leverages OpenZeppelin's upgradeable contracts to ensure future improvements can be made without
 * disrupting service. It employs a non-reentrant pattern for sensitive functions to prevent re-entrancy attacks. Uses a
 * namespaced storage layout for upgradeability. Inherits from `OwnableUpgradeable`, `ReentrancyGuardUpgradeable`, and
 * `UUPSUpgradeable` for ownership management, re-entrancy protection, and upgradeability respectively. Implements
 * `IERC6372` for interoperability with other contract systems. The constructor is replaced by an initializer function
 * to support proxy deployment.
 */
contract DJUSDMinting is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, CommonErrors, IERC6372 {
    using CommonValidations for *;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    struct AssetInfo {
        address oracle;
        bool removed;
    }

    struct RedemptionRequest {
        uint256 amount;
        uint256 claimableAfter;
        uint256 claimed;
        uint256 referenceIndex;
    }

    /// @custom:storage-location erc7201:djinn.storage.DJUSDMinter
    struct DJUSDMinterStorage {
        uint8 activeAssetsLength;
        uint48 claimDelay;
        address custodian;
        EnumerableSet.AddressSet assets;
        mapping(address asset => AssetInfo) assetInfos;
        mapping(address asset => uint256) pendingClaims;
        mapping(address user => mapping(address asset => uint256)) firstUnclaimedIndex;
        mapping(address user => mapping(address asset => RedemptionRequest[])) redemptionRequests;
        mapping(address user => RedemptionRequest[]) allRedemptionRequests;
    }

    IDJUSD public immutable DJUSD;

    // keccak256(abi.encode(uint256(keccak256("djinn.storage.DJUSDMinter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DJUSDMinterStorageLocation =
        0x076ea32f4be917520eed196bef5b8986e4df8b1057872cb20bb9f7e8b6644f00;

    function _getDJUSDMinterStorage() private pure returns (DJUSDMinterStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := DJUSDMinterStorageLocation
        }
    }

    event AssetAdded(address indexed asset, address oracle);
    event AssetRemoved(address indexed asset);
    event AssetRestored(address indexed asset);

    event CustodianUpdated(address indexed custodian);

    event CustodyTransfer(address indexed custodian, address indexed asset, uint256 amount);

    event Mint(address indexed user, address indexed asset, uint256 amount, uint256 received);

    event RebaseDisabled(address indexed asset);

    event TokensRequested(address indexed user, address indexed asset, uint256 amount, uint256 claimableAfter);
    event TokensClaimed(address indexed user, address indexed asset, uint256 amount);

    error InsufficientOutputAmount(uint256 expected, uint256 actual);
    error NotCustodian(address account);
    error NotSupportedAsset(address asset);

    /**
     * @dev Ensures that the provided asset address corresponds to a supported asset within the contract. This modifier
     * is used to validate asset addresses before executing functions that operate on assets, such as minting, claiming,
     * and transferring to custody.
     * Checks against the list of supported assets maintained in the contract's storage. If the asset is not found in
     * this list, the function call is reverted with a `NotSupportedAsset` error.
     * This enforcement guarantees that the contract interacts only with assets that have been verified and approved for
     * use in minting and redemption operations.
     * @param asset The address of the asset to validate.
     * @param includeRemoved If true, the modifier allows the asset to be marked as removed in the list of assets.
     */
    modifier validAsset(address asset, bool includeRemoved) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        if (!$.assets.contains(asset) || (!includeRemoved && $.assetInfos[asset].removed)) {
            revert NotSupportedAsset(asset);
        }
        _;
    }

    /**
     * @notice Initializes the DJUSDMinter contract with a reference to the DJUSD token contract.
     * @dev This constructor sets the immutable DJUSD token contract address, ensuring that the DJUSDMinter contract
     * always interacts with the correct instance of DJUSD.
     * Since this is an upgradeable contract, the constructor does not perform any initialization logic that relies on
     * storage variables. Such logic is handled in the `initialize` function.
     * The constructor is only called once during the initial deployment before the contract is made upgradeable via a
     * proxy.
     * @param djusd The address of the DJUSD token contract. This address is immutable and specifies the DJUSD instance
     * that the minter will interact with.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(IDJUSD djusd) {
        DJUSD = djusd;
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Initializes the DJUSDMinter contract post-deployment to set up initial state and configurations.
     * @dev This function initializes the contract with the OpenZeppelin upgradeable pattern. It sets the initial owner
     * of the contract and the initial claim delay for redemption requests.
     * It must be called immediately after deploying the proxy to ensure the contract is in a valid state. This replaces
     * the constructor logic for upgradeable contracts.
     * @param initialOwner The address that will be granted ownership of the contract, capable of performing
     * administrative actions.
     * @param initialClaimDelay The initial delay time (in seconds) before which a redemption request becomes claimable.
     * This is a security measure to prevent immediate claims post-request.
     * @param initialCustodian The custodian of collateral that will be exchanged for DJUSD tokens.
     */
    function initialize(address initialOwner, uint48 initialClaimDelay, address initialCustodian) public initializer {
        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        $.claimDelay = initialClaimDelay;
        $.custodian = initialCustodian;
    }

    /**
     * @inheritdoc IERC6372
     */
    function clock() public view returns (uint48) {
        return Time.timestamp();
    }

    /**
     * @inheritdoc IERC6372
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @notice Retrieves the current claim delay for redemption requests.
     * @dev This function returns the duration in seconds that must pass before a redemption request becomes claimable.
     * This is a security feature to prevent immediate withdrawals after requesting redemptions, providing a window for
     * administrative checks.
     * @return The current claim delay in seconds.
     */
    function claimDelay() external view returns (uint48) {
        return _getDJUSDMinterStorage().claimDelay;
    }

    /**
     * @notice Sets a new claim delay for the redemption requests.
     * @dev This function allows the contract owner to adjust the claim delay, affecting all future redemption requests.
     * Can be used to respond to changing security requirements or operational needs.
     * Emits a `ValueUnchanged` error if the new delay is the same as the current delay, ensuring that changes are
     * meaningful.
     * @param delay The new claim delay in seconds. Must be different from the current delay to be set successfully.
     */
    function setClaimDelay(uint48 delay) external onlyOwner {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        $.claimDelay.requireDifferentUint48(delay);
        $.claimDelay = delay;
    }

    /**
     * @notice Adds a new asset to the list of supported assets for minting DJUSD.
     * @dev This function marks an asset as supported and disables rebasing for it if applicable. Only callable by the
     * contract owner. It's essential for expanding the range of assets that can be used to mint DJUSD.
     * Attempts to disable rebasing for the asset by calling `disableInitializers` on the asset contract. This is a
     * safety measure for assets that implement a rebase mechanism.
     * @param asset The address of the asset to add. Must be a contract address implementing the IERC20 interface.
     * @param oracle The address of the oracle contract that provides the asset's price feed.
     * @custom:error InvalidZeroAddress The asset address is the zero address.
     * @custom:error InvalidAddress The asset address is the same as the DJUSD address.
     * @custom:error ValueUnchanged The asset is already supported.
     * @custom:event AssetAdded The address of the asset that was added.
     * @custom:event RebaseDisabled The address of the asset for which rebasing was disabled.
     */
    function addSupportedAsset(address asset, address oracle) external onlyOwner {
        asset.requireNonZeroAddress();
        asset.requireNotEqual(address(DJUSD));
        oracle.requireNonZeroAddress();
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        $.assets.requireAbsentAddress(asset);
        $.assets.add(asset);
        $.assetInfos[asset] = AssetInfo({oracle: oracle, removed: false});
        $.activeAssetsLength++;
        // errors in the following low-level call can be ignored
        (bool success,) = asset.call(abi.encodeCall(IRebaseToken.disableRebase, (address(this), true)));
        if (success) {
            emit RebaseDisabled(asset);
        }
        emit AssetAdded(asset, oracle);
    }

    /**
     * @notice Removes an asset from the list of supported assets for minting DJUSD.
     * @dev This function allows the contract owner to remove an asset from the list of supported assets. It's crucial
     * for maintaining the integrity and relevance of the asset pool.
     * @param asset The address of the asset to remove. Must currently be a supported asset.
     * @custom:error NotSupportedAsset The asset is not supported.
     * @custom:event AssetRemoved The address of the asset that was removed.
     */
    function removeSupportedAsset(address asset) external onlyOwner validAsset(asset, false) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        $.assetInfos[asset].removed = true;
        $.activeAssetsLength--;
        emit AssetRemoved(asset);
    }

    function restoreAsset(address asset) external onlyOwner validAsset(asset, true) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        AssetInfo storage assetInfo = $.assetInfos[asset];
        assetInfo.removed.requireDifferentBoolean(false);
        assetInfo.removed = false;
        $.activeAssetsLength++;
        emit AssetRestored(asset);
    }

    /**
     * @notice Updates the custodian state variable.
     * @dev This function allows the contract owner to designate a new custodian, capable of receiving custody transfers
     * of assets. The custodian is a trusted entities that manages the physical or digital custody of assets outside the
     * contract.
     * @param newCustodian The address of the new custodian to be added. Must not already be a custodian.
     * @custom:error InvalidZeroAddress The custodian address is the zero address.
     * @custom:error ValueUnchanged The custodian is already set to the new address.
     * @custom:event CustodianUpdated The address of the custodian that was added.
     */
    function updateCustodian(address newCustodian) external onlyOwner {
        newCustodian.requireNonZeroAddress();
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        $.custodian.requireDifferentAddress(newCustodian);
        $.custodian = newCustodian;
        emit CustodianUpdated(newCustodian);
    }

    /**
     * @notice Mints DJUSD tokens in exchange for a specified amount of a supported asset, which is directly transferred
     * to the custodian.
     * @dev This function facilitates a user to deposit a supported asset directly to the custodian and receive DJUSD
     * tokens in return.
     * The function ensures the asset is supported and employs non-reentrancy protection to prevent double spending.
     * The actual amount of DJUSD minted equals the asset amount received by the custodian, which may vary due to
     * transaction fees or adjustments.
     * The asset is pulled from the user to the custodian directly, ensuring transparency and traceability of asset
     * transfer.
     * @param asset The address of the supported asset to be deposited.
     * @param amountIn The amount of the asset to be transferred from the user to the custodian in exchange for DJUSD.
     * @return amountOut The amount of DJUSD minted and credited to the user's account.
     * @custom:error NotSupportedAsset Indicates the asset is not supported for minting.
     * @custom:event Mint Logs the address of the user who minted, the asset address, the amount deposited, and the
     * amount of DJUSD minted.
     */
    function mint(address asset, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        validAsset(asset, false)
        returns (uint256 amountOut)
    {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        address user = msg.sender;
        address custodian_ = $.custodian;

        amountIn = _pullAssets(user, custodian_, asset, amountIn);

        uint256 balanceBefore = DJUSD.balanceOf(user);
        DJUSD.mint(user, IOracle($.assetInfos[asset].oracle).valueOf(amountIn, Math.Rounding.Floor));

        unchecked {
            amountOut = DJUSD.balanceOf(user) - balanceBefore;
        }

        if (amountOut < minAmountOut) {
            revert InsufficientOutputAmount(minAmountOut, amountOut);
        }

        emit Mint(user, asset, amountIn, amountOut);
    }

    /**
     * @notice Requests the redemption of DJUSD tokens for a specified amount of a supported asset.
     * @dev Allows users to burn DJUSD tokens in exchange for a claim on a specified amount of a supported asset, after
     * a delay defined by `claimDelay`. The request is recorded and can be claimed after the delay period.
     * This function employs non-reentrancy protection and checks that the asset is supported. It burns the requested
     * amount of DJUSD from the user's balance immediately.
     * @param asset The address of the supported asset the user wishes to claim.
     * @param amount The amount of DJUSD the user wishes to redeem for the asset.
     * @custom:error NotSupportedAsset The asset is not supported for redemption.
     * @custom:event TokensRequested The address of the user who requested, the asset address, the amount requested, and
     * the timestamp after which the claim can be made.
     */
    function requestTokens(address asset, uint256 amount) external nonReentrant validAsset(asset, false) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        address user = msg.sender;
        DJUSD.burnFrom(user, amount);
        $.pendingClaims[asset] += amount;
        uint256 claimableAfter = clock() + $.claimDelay;
        RedemptionRequest[] storage allRequests = $.allRedemptionRequests[user];
        RedemptionRequest[] storage assetRequests = $.redemptionRequests[user][asset];
        allRequests.push(
            RedemptionRequest({
                amount: amount,
                claimableAfter: claimableAfter,
                claimed: 0,
                referenceIndex: assetRequests.length
            })
        );
        assetRequests.push(
            RedemptionRequest({
                amount: amount,
                claimableAfter: claimableAfter,
                claimed: 0,
                referenceIndex: allRequests.length - 1
            })
        );
        emit TokensRequested(user, asset, amount, claimableAfter);
    }

    /**
     * @notice Calculates the amount of a supported asset that a user can currently claim from their redemption
     * requests.
     * @dev Returns the total amount of the specified asset that the user is eligible to claim, based on their
     * outstanding redemption requests and the claim delay. This function takes into account only claims that are past
     * the claimable after timestamp.
     * Can return a value less than the total requested if there are insufficient funds in the contract to fulfill the
     * claim.
     * @param user The address of the user for whom to calculate claimable assets.
     * @param asset The address of the supported asset to calculate claimable amounts for.
     * @return amount The total amount of the specified asset that the user can currently claim.
     */
    function claimableTokens(address user, address asset)
        public
        view
        validAsset(asset, true)
        returns (uint256 amount)
    {
        uint256 claimable = _calculateClaimableTokens(user, asset);
        uint256 available = IERC20(asset).balanceOf(address(this));
        return available < claimable ? available : claimable;
    }

    /**
     * @notice Claims the requested supported assets in exchange for previously burned DJUSD tokens, if the claim delay
     * has passed.
     * @dev This function allows users to claim supported assets for which they have previously made redemption requests
     * and the claim delay has elapsed.
     * It checks the amount of assets claimable by the user, ensures the request is valid, and transfers the claimed
     * assets to the user.
     * @param asset The address of the supported asset to be claimed.
     * @param amount The amount of the asset the user wishes to claim.
     * @custom:error InsufficientFunds The requested amount exceeds the claimable amount.
     * @custom:event TokensClaimed The address of the user who claimed, the asset address, and the amount claimed.
     */
    function claimTokens(address asset, uint256 amount) external validAsset(asset, true) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        address user = msg.sender;

        amount.requireSufficientFunds(IERC20(asset).balanceOf(address(this)));

        RedemptionRequest[] storage userRequests = $.allRedemptionRequests[user];
        RedemptionRequest[] storage assetRequests = $.redemptionRequests[user][asset];
        mapping(address asset => uint256) storage firstUnclaimedIndex = $.firstUnclaimedIndex[user];

        uint256 remainingToClaim = _claimTokens(asset, amount, userRequests, assetRequests, firstUnclaimedIndex);

        if (remainingToClaim != 0) {
            unchecked {
                revert InsufficientFunds(amount, amount - remainingToClaim);
            }
        }

        IERC20(asset).safeTransfer(user, amount);

        $.pendingClaims[asset] -= amount;

        emit TokensClaimed(user, asset, amount);
    }

    function _claimTokens(
        address asset,
        uint256 remainingToClaim,
        RedemptionRequest[] storage userRequests,
        RedemptionRequest[] storage assetRequests,
        mapping(address asset => uint256) storage firstUnclaimedIndex
    ) internal returns (uint256) {
        uint256 numRequests = assetRequests.length;
        uint256 i = firstUnclaimedIndex[asset];

        while (i < numRequests) {
            RedemptionRequest storage assetRequest = _unsafeRedemptionRequestAccess(assetRequests, i);
            RedemptionRequest storage userRequest =
                _unsafeRedemptionRequestAccess(userRequests, assetRequest.referenceIndex);
            if (clock() >= assetRequest.claimableAfter) {
                uint256 remainingClaimable;
                (remainingToClaim, remainingClaimable) = _updateClaim(userRequest, assetRequest, remainingToClaim);
                if (remainingToClaim == 0) {
                    unchecked {
                        firstUnclaimedIndex[asset] = remainingClaimable == 0 ? i + 1 : i;
                    }
                    break;
                }
            } else {
                break;
            }
            unchecked {
                ++i;
            }
        }

        return remainingToClaim;
    }

    /**
     * @notice Checks if the specified asset is a supported asset that's acceptable collateral.
     * @param asset The ERC-20 token in question.
     * @return isSupported If true, the specified asset is a supported asset and therefore able to be used to mint
     * DJUSD tokens 1:1.
     */
    function isSupportedAsset(address asset) external view returns (bool isSupported) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        isSupported = $.assets.contains(asset) && !$.assetInfos[asset].removed;
    }

    /**
     * @notice Returns the custodian address stored in this contract
     * @dev The custodian is the address where all collateral from supported assets are transferred during a mint.
     */
    function custodian() external view returns (address) {
        return _getDJUSDMinterStorage().custodian;
    }

    function getRedemptionRequests(address user, uint256 from, uint256 limit)
        external
        view
        returns (RedemptionRequest[] memory requests)
    {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        RedemptionRequest[] storage allRequests = $.allRedemptionRequests[user];
        uint256 numRequests = allRequests.length;
        if (from >= numRequests) {
            requests = new RedemptionRequest[](0);
        } else {
            uint256 to = from + limit;
            if (to > numRequests) {
                to = numRequests;
            }
            unchecked {
                requests = new RedemptionRequest[](to - from);
            }
            for (uint256 i; from != to;) {
                requests[i] = _unsafeRedemptionRequestAccess(allRequests, from);
                unchecked {
                    ++i;
                    ++from;
                }
            }
        }
    }

    function getRedemptionRequests(address user, address asset, uint256 from, uint256 limit)
        external
        view
        returns (RedemptionRequest[] memory requests)
    {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        RedemptionRequest[] storage allRequests = $.redemptionRequests[user][asset];
        uint256 numRequests = allRequests.length;
        if (from >= numRequests) {
            requests = new RedemptionRequest[](0);
        } else {
            uint256 to = from + limit;
            if (to > numRequests) {
                to = numRequests;
            }
            unchecked {
                requests = new RedemptionRequest[](to - from);
            }
            for (uint256 i; from != to;) {
                requests[i] = _unsafeRedemptionRequestAccess(allRequests, from);
                unchecked {
                    ++i;
                    ++from;
                }
            }
        }
    }

    function getAllAssets() external view returns (address[] memory assets) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        assets = $.assets.values();
    }

    function getAllActiveAssets() external view returns (address[] memory assets) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();

        uint256 numAssets = $.assets.length();
        uint256 numActiveAssets = $.activeAssetsLength;

        assets = new address[](numActiveAssets);

        while (numActiveAssets != 0) {
            unchecked {
                --numAssets;
            }
            address asset = $.assets.at(numAssets);
            if (!$.assetInfos[asset].removed) {
                unchecked {
                    --numActiveAssets;
                }
                assets[numActiveAssets] = asset;
            }
        }
    }

    /**
     * @notice Returns the pending claim amount for a specified asset.
     * @param asset ERC-20 collateral that's pending claim
     * @return amount Amount of asset that is pending claim in totality.
     */
    function getPendingClaims(address asset) external view returns (uint256 amount) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        return $.pendingClaims[asset];
    }

    /**
     * @notice Retrieves the amount of a supported asset that is required to fulfill pending redemption requests.
     * @dev This function calculates the total amount of the specified asset that is needed to fulfill all pending
     * redemption requests. It considers the total amount of pending claims for the asset and subtracts the current
     * balance of the asset held in the contract.
     * If the total pending claims exceed the current balance, the function returns the difference as the required
     * amount.
     * @param asset The address of the supported asset to calculate the required amount for.
     * @return amount The total amount of the specified asset required to fulfill pending redemption requests.
     * @custom:error NotSupportedAsset The asset is not supported for redemption.
     */
    function requiredTokens(address asset) public view returns (uint256 amount) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        uint256 totalPendingClaims = $.pendingClaims[asset];
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (totalPendingClaims > balance) {
            unchecked {
                amount = totalPendingClaims - balance;
            }
        }
    }

    /**
     * @dev Calculates the total amount of a supported asset that the specified user can claim based on their redemption
     * requests. This internal view function iterates over the user's redemption requests, summing the amounts of all
     * requests that are past their claimable timestamp.
     * Only considers redemption requests that have not yet been fully claimed and are past the delay period set by
     * `claimDelay`.
     * This function is utilized to determine the amount a user can claim via `claimTokens` and to compute the total
     * claimable amount in `claimableTokens`.
     * @param user The address of the user for whom to calculate the total claimable amount.
     * @param asset The address of the supported asset to calculate claimable amounts for.
     * @return amount The total amount of the supported asset that the user can claim, based on their redemption
     * requests.
     */
    function _calculateClaimableTokens(address user, address asset) internal view returns (uint256 amount) {
        DJUSDMinterStorage storage $ = _getDJUSDMinterStorage();
        RedemptionRequest[] storage userRequests = $.redemptionRequests[user][asset];
        uint256 numRequests = userRequests.length;
        uint256 i = $.firstUnclaimedIndex[user][asset];

        while (i < numRequests) {
            RedemptionRequest storage request = _unsafeRedemptionRequestAccess(userRequests, i);
            if (clock() >= request.claimableAfter) {
                uint256 remainingAmount;
                unchecked {
                    remainingAmount = request.amount - request.claimed;
                }
                amount += remainingAmount;
            } else {
                // Once we hit a request that's not yet claimable, we can break out of the loop early
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Updates the state of a redemption request by claiming a specified amount of the request. This internal
     * function is used to update the state of a redemption request during the claiming process.
     * It calculates the remaining claimable amount and the amount left to claim after the current claim operation.
     * The function returns the remaining amount to claim and the remaining claimable amount after the claim.
     * @param userRequest The storage pointer to the user's redemption request.
     * @param assetRequest The storage pointer to the user's asset-specific redemption request.
     * @param amount The amount to claim from the request.
     * @return remainingToClaim The remaining amount to claim after the current operation.
     * @return remainingClaimable The remaining claimable amount after the current operation.
     */
    function _updateClaim(RedemptionRequest storage userRequest, RedemptionRequest storage assetRequest, uint256 amount)
        internal
        returns (uint256, uint256)
    {
        uint256 requested = userRequest.amount;
        uint256 remainingClaimable;
        unchecked {
            remainingClaimable = requested - userRequest.claimed;
        }
        if (remainingClaimable < amount) {
            userRequest.claimed = requested;
            assetRequest.claimed = requested;
            unchecked {
                amount -= remainingClaimable;
                remainingClaimable = 0;
            }
        } else {
            uint256 claimed;
            unchecked {
                claimed = userRequest.claimed + amount;
                remainingClaimable = requested - claimed;
            }
            userRequest.claimed = claimed;
            assetRequest.claimed = claimed;
            amount = 0;
        }
        return (amount, remainingClaimable);
    }

    /**
     * @dev Transfers a specified amount of a supported asset from a user's address directly to the custodian, adjusted
     * based on the redemption requirements.
     * This function is crucial during the minting process or when managing redemption requests. It assesses the total
     * amount of the asset that is required to fulfill unclaimed redemption requests.
     * If no additional tokens are needed for pending redemptions (i.e., required tokens are zero), the asset is
     * directly transferred from the user to the custodian.
     * If there are outstanding redemption obligations, the asset is initially transferred to this contract to ensure
     * adequate availability for future claims. Excess tokens, beyond what is required for redemptions, are subsequently
     * transferred to the custodian.
     * This structured approach ensures that sufficient assets are always on hand to meet redemption claims while
     * effectively managing incoming asset deposits for minting.
     * @param user The address from which the asset will be pulled.
     * @param custodian_ The custodian to whom the asset will be transferred, either directly or after fulfilling
     * redemption requirements.
     * @param asset The address of the supported asset to be transferred.
     * @param amount The intended amount of the asset to transfer from the user. The function calculates the actual
     * transfer based on the asset’s pending redemption needs.
     * @return received The actual amount of the asset received by the contract or the custodian, which may differ from
     * the intended amount due to transaction fees or after considering the required redemption amount.
     * @custom:event CustodyTransfer Logs the transfer of the asset to the custodian, detailing the amount and involved
     * parties.
     */
    function _pullAssets(address user, address custodian_, address asset, uint256 amount)
        internal
        returns (uint256 received)
    {
        uint256 required = requiredTokens(asset);
        address recipient = required == 0 ? custodian_ : address(this);

        uint256 balanceBefore = IERC20(asset).balanceOf(recipient);
        IERC20(asset).safeTransferFrom(user, recipient, amount);
        received = IERC20(asset).balanceOf(recipient) - balanceBefore;

        if (required != 0 && required < received) {
            unchecked {
                uint256 toSend = received - required;
                IERC20(asset).safeTransfer(custodian_, toSend);
                emit CustodyTransfer(custodian_, asset, toSend);
            }
        }
    }

    /**
     * @dev Provides low-level, unchecked access to a specific redemption request within the user's array of requests.
     * This function is a critical component for manipulating redemption requests efficiently in storage.
     * It utilizes assembly to directly compute the storage slot of the requested index, bypassing Solidity's safety
     * checks. This method is used internally to update the state of redemption requests during the claiming process.
     * Care must be taken when using this function due to the lack of bounds checking; incorrect usage could lead to
     * undefined behavior or contract vulnerabilities.
     * @param arr The storage array containing the user's redemption requests.
     * @param pos The index of the redemption request within the array to access.
     * @return request A storage pointer to the `RedemptionRequest` at the specified index in the array.
     */
    function _unsafeRedemptionRequestAccess(RedemptionRequest[] storage arr, uint256 pos)
        internal
        pure
        returns (RedemptionRequest storage request)
    {
        assembly {
            mstore(0, arr.slot)
            request.slot := add(keccak256(0, 0x20), mul(pos, 4))
        }
    }
}
