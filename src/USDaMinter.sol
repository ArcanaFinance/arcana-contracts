// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {Arrays, StorageSlot} from "@openzeppelin/contracts/utils/Arrays.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

// tangible imports
import {RebaseTokenMath} from "@tangible/contracts/libraries/RebaseTokenMath.sol";

// interfaces
import {CommonErrors} from "./interfaces/CommonErrors.sol";
import {IUSDa} from "./interfaces/IUSDa.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

// libs
import {CommonValidations} from "./libraries/CommonValidations.sol";

/**
 * @title USDa Minter
 * @author Caesar LaVey
 *
 * @notice USDaMinter facilitates the minting and redemption process of USDa tokens against various supported assets.
 * It allows for adding and removing assets and custodians, minting USDa by depositing assets, and requesting
 * redemption of USDa for assets. The contract uses a delay mechanism for redemptions to enhance security and manages
 * custody transfers of assets to designated custodians.
 *
 * @dev The contract leverages OpenZeppelin's upgradeable contracts to ensure future improvements can be made without
 * disrupting service. It employs a non-reentrant pattern for sensitive functions to prevent re-entrancy attacks. Uses a
 * namespaced storage layout for upgradeability. Inherits from `OwnableUpgradeable`, `ReentrancyGuardUpgradeable`, and
 * `UUPSUpgradeable` for ownership management, re-entrancy protection, and upgradeability respectively. Implements
 * `IERC6372` for interoperability with other contract systems. The constructor is replaced by an initializer function
 * to support proxy deployment.
 */
contract USDaMinter is OwnableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, CommonErrors, IERC6372 {
    using Arrays for uint256[];
    using CommonValidations for *;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for *;
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    struct AssetInfo {
        address oracle;
        bool removed;
    }

    struct RedemptionRequest {
        uint256 amount;
        uint256 claimed;
        address asset;
        uint48 claimableAfter;
    }

    /// @custom:storage-location erc7201:arcana.storage.USDaMinter
    struct USDaMinterStorage {
        Checkpoints.Trace208 coverageRatio;
        EnumerableSet.AddressSet assets;
        mapping(address asset => AssetInfo) assetInfos;
        mapping(address asset => uint256) pendingClaims;
        mapping(address user => mapping(address asset => uint256)) firstUnclaimedIndex;
        mapping(address user => mapping(address asset => uint256[])) redemptionRequestsByAsset;
        mapping(address user => RedemptionRequest[]) redemptionRequests;
        mapping(address user => bool) isWhitelisted;
        uint256 maxAge;
        address custodian;
        address admin;
        address whitelister;
        uint48 claimDelay;
        uint8 activeAssetsLength;
    }

    IUSDa public immutable USDa;

    // keccak256(abi.encode(uint256(keccak256("arcana.storage.USDaMinter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant USDaMinterStorageLocation =
        0x70b533cc9d2662f7b017cf7a562919e2eb5c285358c6b5315aa15e465920a900;

    function _getUSDaMinterStorage() private pure returns (USDaMinterStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := USDaMinterStorageLocation
        }
    }

    event AssetAdded(address indexed asset, address indexed oracle);
    event OracleUpdated(address indexed asset, address indexed oracle);
    event AssetRemoved(address indexed asset);
    event AssetRestored(address indexed asset);
    event ClaimDelayUpdated(uint48 claimDelay);
    event CoverageRatioUpdated(uint256 ratio);
    event MaxAgeUpdated(uint256 newMaxAge);
    event CustodianUpdated(address indexed custodian);
    event AdminUpdated(address indexed admin);
    event WhitelisterUpdated(address indexed whitelister);
    event WhitelistStatusUpdated(address indexed whitelister, bool isWhitelisted);
    event CustodyTransfer(address indexed custodian, address indexed asset, uint256 amount);
    event Mint(address indexed user, address indexed asset, uint256 amount, uint256 received);
    event RebaseDisabled(address indexed asset);
    event TokensRequested(
        address indexed user,
        address indexed asset,
        uint256 indexed index,
        uint256 amountUSDa,
        uint256 amountCollateral,
        uint256 claimableAfter
    );
    event TokenRequestUpdated(
        address indexed user,
        address indexed asset,
        uint256 indexed index,
        uint256 amount,
        uint256 oldClaimableAfter,
        uint256 newClaimableAfter
    );
    event TokensClaimed(address indexed user, address indexed asset, uint256 usdaAmount, uint256 claimed);

    error InsufficientOutputAmount(uint256 expected, uint256 actual);
    error NoTokensClaimable();
    error NotCustodian(address account);
    error NotSupportedAsset(address asset);
    error NotAdmin(address account);
    error NotWhitelisted(address account);
    error NotWhitelister(address account);
    error NoFundsWithdrawable(uint256 required, uint256 balance);
    error InsufficientWithdrawable(uint256 canWithdraw, uint256 amount);

    /**
     * @dev Ensures that the function can only be called by the contract's designated custodian. This modifier enforces
     * role-based access control for sensitive functions that manage or alter asset states or user claims.
     * @custom:error NotCustodian Thrown if the caller is not the current custodian of the contract.
     */
    modifier onlyCustodian() {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        if (msg.sender != $.custodian) {
            revert NotCustodian(msg.sender);
        }
        _;
    }

    /**
     * @dev Ensures that the function can only be called by the contract's designated admin. This modifier enforces
     * role-based access control for sensitive functions that manage or alter asset states or user claims.
     * @custom:error NotAdmin Thrown if the caller is not the current admin of the contract.
     */
    modifier onlyAdmin() {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        if (msg.sender != $.admin && msg.sender != owner()) {
            revert NotAdmin(msg.sender);
        }
        _;
    }

    /**
     * @dev Ensures that the function can only be called by a whitelisted address. This modifier enforces
     * role-based access control for minting and redeeming tokens. We use a whitelist mechanism to mitigate
     * US-based users from interacting with the contract.
     * @custom:error NotWhitelisted Thrown if the caller is not currently whitelisted.
     */
    modifier onlyWhitelisted() {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        if (!$.isWhitelisted[msg.sender]) {
            revert NotWhitelisted(msg.sender);
        }
        _;
    }

    /**
     * @dev Ensures that the function can only be called by a whitelister address. This modifier enforces
     * role-based access control for granting whitelist capabilities (mint, requestTokens, and claim) to EOAs.
     * This address will most likely coincide with a gelato task for facilitating whitelists.
     * @custom:error NotWhitelister Thrown if the caller is not the current whitelister of the contract.
     */
    modifier onlyWhitelister() {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        if (msg.sender != $.whitelister && msg.sender != owner()) {
            revert NotWhitelister(msg.sender);
        }
        _;
    }

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
        asset.requireNonZeroAddress();
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        if (!$.assets.contains(asset) || (!includeRemoved && $.assetInfos[asset].removed)) {
            revert NotSupportedAsset(asset);
        }
        _;
    }

    /**
     * @notice Initializes the USDaMinter contract with a reference to the USDa token contract.
     * @dev This constructor sets the immutable USDa token contract address, ensuring that the USDaMinter contract
     * always interacts with the correct instance of USDa.
     * Since this is an upgradeable contract, the constructor does not perform any initialization logic that relies on
     * storage variables. Such logic is handled in the `initialize` function.
     * The constructor is only called once during the initial deployment before the contract is made upgradeable via a
     * proxy.
     * @param usda The address of the USDa token contract. This address is immutable and specifies the USDa instance
     * that the minter will interact with.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(IUSDa usda) {
        address(usda).requireNonZeroAddress();
        USDa = usda;
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Initializes the USDaMinter contract post-deployment to set up initial state and configurations.
     * @dev This function initializes the contract with the OpenZeppelin upgradeable pattern. It sets the initial owner
     * of the contract and the initial claim delay for redemption requests.
     * It must be called immediately after deploying the proxy to ensure the contract is in a valid state. This replaces
     * the constructor logic for upgradeable contracts.
     * @param initialOwner The address that will be granted ownership of the contract, capable of performing
     * administrative actions.
     * @param initialAdmin The address that has the ability to extend timestamp endTimes of redemption requests.
     * @param initialWhitelister The address capable of whitelisting EOAs, granting them the ability to mint, request redeems, and claim.
     * @param initialClaimDelay The initial delay time (in seconds) before which a redemption request becomes claimable.
     * This is a security measure to prevent immediate claims post-request.
     */
    function initialize(address initialOwner, address initialAdmin, address initialWhitelister, uint48 initialClaimDelay) public initializer {
        initialOwner.requireNonZeroAddress();
        initialAdmin.requireNonZeroAddress();
        initialWhitelister.requireNonZeroAddress();

        __Ownable_init(initialOwner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.admin = initialAdmin;
        $.whitelister = initialWhitelister;
        $.claimDelay = initialClaimDelay;
        $.coverageRatio.push(clock(), 1e18);
        $.isWhitelisted[initialOwner] = true;
        $.maxAge = 1 hours;
    }

    /**
     * @notice Sets a new claim delay for the redemption requests.
     * @dev This function allows the contract owner to adjust the claim delay, affecting all future redemption requests.
     * Can be used to respond to changing security requirements or operational needs.
     * Emits a `ValueUnchanged` error if the new delay is the same as the current delay, ensuring that changes are
     * meaningful.
     * @param delay The new claim delay in seconds. Must be different from the current delay to be set successfully.
     */
    function setClaimDelay(uint48 delay) external nonReentrant onlyOwner {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.claimDelay.requireDifferentUint48(delay);
        $.claimDelay = delay;
        emit ClaimDelayUpdated(delay);
    }

    /**
     * @notice This method allows the admin to update the coverageRatio.
     * @dev The coverageRatio cannot be greater than 1e18. In the event the protocol's collateral is less than the amount needed
     * to fund 100% of requests, this ratio would be set to sub-1e18 until the protocol goes back to 100%.
     * @param ratio New ratio.
     */
    function setCoverageRatio(uint256 ratio) external nonReentrant onlyAdmin {
        ratio.requireLessThanOrEqualToUint256(1e18);
        latestCoverageRatio().requireDifferentUint256(ratio);
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.coverageRatio.push(clock(), uint208(ratio));
        emit CoverageRatioUpdated(ratio);
    }

    /**
     * @notice This method allows the owner to update the maxAge
     * @dev The maxAge is the amount of time we will continue to take an oracle's price before we deem it "stale".
     * @param newMaxAge New max age for oracle prices.
     */
    function setMaxAge(uint256 newMaxAge) external onlyOwner {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.maxAge.requireDifferentUint256(newMaxAge);
        $.maxAge = newMaxAge;
        emit MaxAgeUpdated(newMaxAge);
    }

    /**
     * @notice Allows the custodian to withdraw collateral from this contract.
     * @dev This function takes into account the required assets and only allows the custodian to claim the difference
     * between what is required and the balance in this contract assuming the balance is greater than what is required.
     * @param asset ERC-20 asset being withdrawn from this contract. Does not need to be a valid collateral token.
     * @param amount Amount of asset that is being withdrawn. Mustn't be greater than what is available (balance - required).
     * @custom:error NotCustodian Thrown if the caller is not the custodian address.
     * @custom:error NoFundsWithdrawable Thrown if there are no funds to be withdrawn or amount exceeds withdrawable.
     * @custom:event CustodyTransfer Amount of asset transferred to what custodian.
     */
    function withdrawFunds(address asset, uint256 amount) external nonReentrant onlyCustodian {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        uint256 required = $.pendingClaims[asset];
        uint256 bal = IERC20(asset).balanceOf(address(this));

        if (bal > required) {
            address _custodian = $.custodian;
            unchecked {
                uint256 canSend = bal - required;
                if (amount > canSend) revert InsufficientWithdrawable(canSend, amount);
                IERC20(asset).safeTransfer(_custodian, amount);
                emit CustodyTransfer(_custodian, asset, amount);
            }
        }
        else {
            revert NoFundsWithdrawable(required, bal);
        }
    }

    /**
     * @notice Allows the whitelister to change the whitelist status of an address.
     * @dev The whitelist status of an address allows that address to execute mint, requestTokens, and claimTokens.
     * These methods are protected by the whitelist role to stop any EOAs from restricted countries from interacting
     * with the contract.
     * @param account Address whitelist role is being udpated.
     * @param whitelisted Status to set whitelist role to. If true, account is whitelisted.
     * @custom:error NotWhitelister Thrown if the caller is not the whitelister address or owner.
     * @custom:error InvalidZeroAddress Thrown if `account` is address(0).
     * @custom:error ValueUnchanged Thrown if `whitelisted` is the current whitelist status of account.
     */
    function modifyWhitelist(address account, bool whitelisted) external onlyWhitelister {
        account.requireNonZeroAddress();
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.isWhitelisted[account].requireDifferentBoolean(whitelisted);
        $.isWhitelisted[account] = whitelisted;
        emit WhitelistStatusUpdated(account, whitelisted);
    }

    /**
     * @notice Adds a new asset to the list of supported assets for minting USDa.
     * @dev This function marks an asset as supported and disables rebasing for it if applicable. Only callable by the
     * contract owner. It's essential for expanding the range of assets that can be used to mint USDa.
     * Attempts to disable rebasing for the asset by calling `disableInitializers` on the asset contract. This is a
     * safety measure for assets that implement a rebase mechanism.
     * @param asset The address of the asset to add. Must be a contract address implementing the IERC20 interface.
     * @param oracle The address of the oracle contract that provides the asset's price feed.
     * @custom:error InvalidAddress The asset address is the same as the USDa address.
     * @custom:error ValueUnchanged The asset is already supported.
     * @custom:event AssetAdded The address of the asset that was added.
     * @custom:event RebaseDisabled The address of the asset for which rebasing was disabled.
     */
    function addSupportedAsset(address asset, address oracle) external onlyOwner {
        asset.requireNonZeroAddress();
        asset.requireNotEqual(address(USDa));
        oracle.requireNonZeroAddress();
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
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
     * @notice Updates the oracle address for a supported asset.
     * @dev The asset must already be a supported asset. This will only update the oracle used to quote mints and
     * redemptions for that asset.
     * @param asset The address of the supported asset.
     * @param newOracle The address of the new oracle contract that provides the asset's price feed.
     * @custom:error ValueUnchanged The asset is already supported.
     * @custom:event OracleUpdated The address of the asset that was added.
     */
    function modifyOracleForAsset(address asset, address newOracle) external onlyOwner validAsset(asset, true) {
        newOracle.requireNonZeroAddress();
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        newOracle.requireDifferentAddress($.assetInfos[asset].oracle);
        $.assetInfos[asset].oracle = newOracle;
        emit OracleUpdated(asset, newOracle);
    }

    /**
     * @notice Removes an asset from the list of supported assets for minting USDa, making it ineligible for future
     * operations until restored.
     * @dev This function allows the contract owner to temporarily remove an asset from the list of supported assets.
     * Removed assets can be restored using the `restoreAsset` function. It is crucial for managing the lifecycle and
     * integrity of the asset pool.
     * @param asset The address of the asset to remove. Must currently be a supported and not previously removed asset.
     * @custom:error NotSupportedAsset Thrown if the asset is not currently supported or has already been removed.
     * @custom:event AssetRemoved Logs the removal of the asset.
     */
    function removeSupportedAsset(address asset) external onlyOwner validAsset(asset, false) {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.assetInfos[asset].removed = true;
        $.activeAssetsLength--;
        emit AssetRemoved(asset);
    }

    /**
     * @notice Restores a previously removed asset, making it eligible for minting and redemption processes again.
     * @dev This function allows the contract owner to reactivate a previously removed asset. It is crucial for managing
     * the lifecycle of assets, especially in cases where an asset needs to be temporarily disabled and later
     * reintroduced.
     * The asset must currently be marked as removed to be eligible for restoration.
     * @param asset The address of the asset to restore.
     * @custom:error NotSupportedAsset Thrown if the asset is not found in the list of assets or is not currently marked
     * as removed.
     * @custom:error ValueUnchanged Thrown if the asset is already active.
     * @custom:event AssetRestored Logs the restoration of the asset, making it active again.
     */
    function restoreAsset(address asset) external onlyOwner validAsset(asset, true) {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
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
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.custodian.requireDifferentAddress(newCustodian);
        $.custodian = newCustodian;
        emit CustodianUpdated(newCustodian);
    }

    /**
     * @notice Updates the admin state variable.
     * @dev This function allows the contract owner to designate a new admin, capable of extending claimAfter times
     * for requests and manipulating the coverageRatio variable.
     * @param newAdmin The address of the new admin to be added.
     * @custom:error InvalidZeroAddress The admin address is the zero address.
     * @custom:error ValueUnchanged The admin is already set to the new address.
     * @custom:event AdminUpdated The address of the admin that was added.
     */
    function updateAdmin(address newAdmin) external onlyOwner {
        newAdmin.requireNonZeroAddress();
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.admin.requireDifferentAddress(newAdmin);
        $.admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }

    /**
     * @notice Updates the whitelister state variable.
     * @dev This function allows the contract owner to designate a new whitelister, capable of modifying the whitelist
     * status of EOA, granting them the ability to mint, requestTokens, and claimTokens.
     * @param newWhitelister The address of the new whitelister to be added.
     * @custom:error InvalidZeroAddress The whitelister address is the zero address.
     * @custom:error ValueUnchanged The whitelister is already set to the new address.
     * @custom:event WhitelisterUpdated The address of the whitelister that was added.
     */
    function updateWhitelister(address newWhitelister) external onlyOwner {
        newWhitelister.requireNonZeroAddress();
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        $.whitelister.requireDifferentAddress(newWhitelister);
        $.whitelister = newWhitelister;
        emit WhitelisterUpdated(newWhitelister);
    }

    /**
     * @notice Mints USDa tokens in exchange for a specified amount of a supported asset, which is directly transferred
     * to the custodian.
     * @dev This function facilitates a user to deposit a supported asset directly to the custodian and receive USDa
     * tokens in return.
     * The function ensures the asset is supported and employs non-reentrancy protection to prevent double spending.
     * The actual amount of USDa minted equals the asset amount received by the custodian, which may vary due to
     * transaction fees or adjustments.
     * The asset is pulled from the user to the custodian directly, ensuring transparency and traceability of asset
     * transfer.
     * @param asset The address of the supported asset to be deposited.
     * @param amountIn The amount of the asset to be transferred from the user to the custodian in exchange for USDa.
     * @return amountOut The amount of USDa minted and credited to the user's account.
     * @custom:error NotSupportedAsset Indicates the asset is not supported for minting.
     * @custom:event Mint Logs the address of the user who minted, the asset address, the amount deposited, and the
     * amount of USDa minted.
     */
    function mint(address asset, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        validAsset(asset, false)
        onlyWhitelisted
        returns (uint256 amountOut)
    {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        address user = msg.sender;

        amountIn = _pullAssets(user, asset, amountIn);

        uint256 balanceBefore = USDa.balanceOf(user);
        USDa.mint(user, IOracle($.assetInfos[asset].oracle).valueOf(amountIn, $.maxAge, Math.Rounding.Floor));

        unchecked {
            amountOut = USDa.balanceOf(user) - balanceBefore;
        }

        if (amountOut < minAmountOut) {
            revert InsufficientOutputAmount(minAmountOut, amountOut);
        }

        emit Mint(user, asset, amountIn, amountOut);
    }

    /**
     * @notice Requests the redemption of USDa tokens for a specified amount of a supported asset.
     * @dev Allows users to burn USDa tokens in exchange for a claim on a specified amount of a supported asset, after
     * a delay defined by `claimDelay`. The request is recorded and can be claimed after the delay period.
     * This function employs non-reentrancy protection and checks that the asset is supported. It burns the requested
     * amount of USDa from the user's balance immediately.
     * @param asset The address of the supported asset the user wishes to claim.
     * @param amount The amount of USDa the user wishes to redeem for the asset.
     * @custom:error NotSupportedAsset The asset is not supported for redemption.
     * @custom:event TokensRequested The address of the user who requested, the asset address, the amount requested, and
     * the timestamp after which the claim can be made.
     */
    function requestTokens(address asset, uint256 amount) external nonReentrant validAsset(asset, false) onlyWhitelisted {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        address user = msg.sender;
        USDa.burnFrom(user, amount);
        uint256 amountAsset = IOracle(_getUSDaMinterStorage().assetInfos[asset].oracle).amountOf(amount, $.maxAge, Math.Rounding.Floor);
        $.pendingClaims[asset] += amountAsset;
        uint48 claimableAfter = clock() + $.claimDelay;
        RedemptionRequest[] storage userRequests = $.redemptionRequests[user];
        uint256[] storage userRequestsByAsset = $.redemptionRequestsByAsset[user][asset];
        userRequests.push(RedemptionRequest({asset: asset, amount: amountAsset, claimableAfter: claimableAfter, claimed: 0}));
        uint256 index;
        unchecked {
            index = (userRequests.length - 1).toUint32();
        }
        userRequestsByAsset.push(index);
        emit TokensRequested(user, asset, index, amount, amountAsset, claimableAfter);
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
        external
        view
        validAsset(asset, true)
        returns (uint256 amount)
    {
        uint256 claimable = _calculateClaimableTokens(user, asset);
        uint256 available = IERC20(asset).balanceOf(address(this));
        return available < claimable ? available : claimable;
    }

    /**
     * @notice Claims the requested supported assets in exchange for previously burned USDa tokens, if the claim delay
     * has passed.
     * @dev This function allows users to claim supported assets for which they have previously made redemption requests
     * and the claim delay has elapsed.
     * Uses `_unsafeRedemptionRequestByAssetAccess` to access redemption requests directly in storage, optimizing gas
     * usage.
     * @param asset The address of the supported asset to be claimed.
     * @custom:error InsufficientFunds The requested amount exceeds the claimable amount.
     * @custom:error NoTokensClaimable There are no tokens that can be claimed.
     * @custom:event TokensClaimed The address of the user who claimed, the asset address, and the amount claimed.
     */
    function claimTokens(address asset) external nonReentrant validAsset(asset, true) onlyWhitelisted {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        address user = msg.sender;

        RedemptionRequest[] storage userRequests = $.redemptionRequests[user];
        uint256[] storage userRequestsByAsset = $.redemptionRequestsByAsset[user][asset];
        mapping(address asset => uint256) storage firstUnclaimedIndex = $.firstUnclaimedIndex[user];
        Checkpoints.Trace208 storage ratio = $.coverageRatio;

        (uint256 amountRequested, uint256 amountToClaim) = _claimTokens(
            asset,
            userRequests,
            userRequestsByAsset,
            firstUnclaimedIndex,
            ratio
        );

        if (amountToClaim == 0) revert NoTokensClaimable();

        amountToClaim.requireSufficientFunds(IERC20(asset).balanceOf(address(this)));

        IERC20(asset).safeTransfer(user, amountToClaim);
        $.pendingClaims[asset] -= amountRequested;

        emit TokensClaimed(user, asset, amountRequested, amountToClaim);
    }

    /**
     * @notice Extends the claimable after timestamp for a specific redemption request.
     * @dev Allows the custodian to delay the claimability of assets for a particular redemption request. This can be
     * used in scenarios where additional time is needed before the assets can be released or in response to changing
     * conditions affecting the asset or market stability.
     * This action updates both the general and asset-specific redemption request entries to ensure consistency across
     * the contract's tracking mechanisms.
     * @param user The address of the user whose redemption request is being modified.
     * @param asset The asset for which the redemption request was made.
     * @param index The index of the redemption request in the user's general array of requests.
     * @param newClaimableAfter The new timestamp after which the redemption request can be claimed. Must be later than
     * the current claimable after timestamp.
     * @custom:error NotAdmin Thrown if the caller is not the designated custodian.
     * @custom:error ValueBelowMinimum Thrown if the new claimable after timestamp is not later than the existing one.
     * @custom:event TokenRequestUpdated Logs the update of the claimable after timestamp, providing the old and new
     * timestamps.
     */
    function extendClaimTimestamp(address user, address asset, uint256 index, uint48 newClaimableAfter)
        external
        onlyAdmin
    {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        RedemptionRequest storage request = $.redemptionRequests[user][index];
        uint48 claimableAfter = request.claimableAfter;
        claimableAfter.requireLessThanUint48(newClaimableAfter);
        request.claimableAfter = newClaimableAfter;
        emit TokenRequestUpdated(user, asset, index, request.amount, claimableAfter, newClaimableAfter);
    }

    /**
     * @notice Returns the custodian address stored in this contract.
     * @dev The custodian manages the collateral collected by this contract.
     */
    function custodian() external view returns (address) {
        return _getUSDaMinterStorage().custodian;
    }

    /**
     * @notice Returns the admin address stored in this contract.
     * @dev The admin is responsible for extending request times and setting the coverage ratio.
     */
    function admin() external view returns (address) {
        return _getUSDaMinterStorage().admin;
    }

    /**
     * @notice Returns the whitelister address stored in this contract.
     * @dev The whitelister is responsible for managing whitelist status of EOAs.
     */
    function whitelister() external view returns (address) {
        return _getUSDaMinterStorage().whitelister;
    }

    /**
     * @notice Returns if the specified account is whitelisted
     * @dev If the account is whitelisted, they have the ability to call mint, requestTokens, and claimTokens.
     */
    function isWhitelisted(address account) external view returns (bool) {
        return _getUSDaMinterStorage().isWhitelisted[account];
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
        return _getUSDaMinterStorage().claimDelay;
    }

    /**
     * @notice Checks if the specified asset is a supported asset that's acceptable collateral.
     * @param asset The ERC-20 token in question.
     * @return isSupported If true, the specified asset is a supported asset and therefore able to be used to mint
     * USDa tokens 1:1.
     */
    function isSupportedAsset(address asset) external view returns (bool isSupported) {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        isSupported = $.assets.contains(asset) && !$.assetInfos[asset].removed;
    }

    /**
     * @notice Retrieves a list of all redemption requests for a specified user within a range.
     * @dev This function returns an array of redemption requests made by the specified user across all assets, limited
     * by a specified range.
     * Utilizes the `_unsafeRedemptionRequestAccess` to efficiently access storage without bounds checking.
     * It is crucial to ensure that input ranges are validated externally to prevent out-of-bounds access.
     * @param user The address of the user whose redemption requests are being queried.
     * @param from The starting index in the list of redemption requests to begin retrieval from.
     * @param limit The maximum number of redemption requests to return.
     * @return requests An array of redemption requests from the specified start index up to the limit.
     */
    function getRedemptionRequests(address user, uint256 from, uint256 limit)
        external
        view
        returns (RedemptionRequest[] memory requests)
    {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        RedemptionRequest[] storage userRequests = $.redemptionRequests[user];
        uint256 numRequests = userRequests.length;
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
                requests[i] = _unsafeRedemptionRequestAccess(userRequests, from);
                unchecked {
                    ++i;
                    ++from;
                }
            }
        }
    }

    /**
     * @notice Retrieves a list of redemption requests for a specified user and asset within a range.
     * @dev This function returns an array of redemption requests made by the specified user for a particular asset,
     * limited by a specified range.
     * It makes use of `_unsafeRedemptionRequestByAssetAccess` for direct storage access with given indices, avoiding
     * the gas cost of bounds checking.
     * The integrity of indices and their range should be maintained and verified elsewhere in the contract logic to
     * prevent errors.
     * @param user The address of the user whose redemption requests for a specific asset are being queried.
     * @param asset The ERC-20 token for which redemption requests are being queried.
     * @param from The starting index in the list of redemption requests to begin retrieval from.
     * @param limit The maximum number of redemption requests to return.
     * @return requests An array of redemption requests specific to the asset from the specified start index up to the
     * limit.
     */
    function getRedemptionRequests(address user, address asset, uint256 from, uint256 limit)
        external
        view
        returns (RedemptionRequest[] memory requests)
    {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        RedemptionRequest[] storage userRequests = $.redemptionRequests[user];
        uint256[] storage userRequestsByAsset = $.redemptionRequestsByAsset[user][asset];
        uint256 numRequests = userRequestsByAsset.length;
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
                requests[i] = _unsafeRedemptionRequestByAssetAccess(userRequestsByAsset, userRequests, from);
                unchecked {
                    ++i;
                    ++from;
                }
            }
        }
    }

    /**
     * @notice Retrieves a list of all assets registered in the contract, regardless of their active or removed status.
     * @dev This function returns an array of all asset addresses that have been added to the contract over time. It
     * includes both currently active and previously removed assets, providing a comprehensive view of the contract's
     * historical asset management.
     * Useful for audit purposes or for administrative overview to see the full range of assets ever involved with the
     * contract.
     * @return assets An array of addresses representing all assets that have been registered in the contract.
     */
    function getAllAssets() external view returns (address[] memory assets) {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        assets = $.assets.values();
    }

    /**
     * @notice Retrieves a list of all currently active assets that are eligible for minting and redemption.
     * @dev This function returns an array of asset addresses that are currently active, i.e., not marked as removed. It
     * filters out the assets that have been deactivated or removed from active operations.
     * This is particularly useful for users or interfaces interacting with the contract, needing to know which assets
     * are currently operational for minting and redemption processes.
     * @return assets An array of addresses representing all active assets in the contract.
     */
    function getActiveAssets() external view returns (address[] memory assets) {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();

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
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        amount = $.pendingClaims[asset];
    }

    /**
     * @notice Provides a quote of USDa tokens a user would receive if they used a specified amountIn of an asset to
     * mint USDa.
     * @dev Accounts for the user's rebase opt-out status. If opted out, a 1:1 ratio is used. Otherwise, rebase
     * adjustments apply.
     * @param asset The address of the supported asset to calculate the quote for.
     * @param from The account whose opt-out status to check.
     * @param amountIn The amount of collateral being used to mint USDa.
     * @return assets The amount of USDa `from` would receive if they minted with `amountIn` of `asset`.
     */
    function quoteMint(address asset, address from, uint256 amountIn)
        external
        view
        validAsset(asset, false)
        returns (uint256 assets)
    {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        (bool success, bytes memory data) = asset.staticcall(abi.encodeCall(IRebaseToken.optedOut, (address(this))));
        if (success) {
            bool isOptedOut = abi.decode(data, (bool));
            if (!isOptedOut) {
                (,data) = asset.staticcall(abi.encodeCall(IRebaseToken.optedOut, (from)));
                isOptedOut = abi.decode(data, (bool));
                if (!isOptedOut) {
                    uint256 rebaseIndex = IRebaseToken(asset).rebaseIndex();
                    uint256 usdaShares = RebaseTokenMath.toShares(amountIn, rebaseIndex);
                    amountIn = RebaseTokenMath.toTokens(usdaShares, rebaseIndex);
                }
            }
        }
        assets = IOracle(_getUSDaMinterStorage().assetInfos[asset].oracle).valueOf(amountIn, $.maxAge, Math.Rounding.Floor);
    }

    /**
     * @notice Provides a quote of assets a user would receive if they used a specified amountIn of USDa to
     * redeem assets.
     * @dev Accounts for the user's rebase opt-out status. If opted out, a 1:1 ratio is used. Otherwise, rebase
     * adjustments apply.
     * @param asset The address of the supported asset to calculate the quote for.
     * @param from The account whose opt-out status to check.
     * @param amountIn The amount of USDa being used to redeem collateral.
     * @return collateral The amount of collateral `from` would receive if they redeemed with `amountIn` of USDa.
     */
    function quoteRedeem(address asset, address from, uint256 amountIn)
        external
        view
        validAsset(asset, false)
        returns (uint256 collateral)
    {
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        (bool success, bytes memory data) = address(USDa).staticcall(abi.encodeCall(IRebaseToken.optedOut, (from)));
        if (success) {
            bool isOptedOut = abi.decode(data, (bool));
            if (!isOptedOut) {
                uint256 rebaseIndex = IRebaseToken(address(USDa)).rebaseIndex();
                uint256 usdaShares = RebaseTokenMath.toShares(amountIn, rebaseIndex);
                amountIn = RebaseTokenMath.toTokens(usdaShares, rebaseIndex);
            }
        }
        collateral = IOracle(_getUSDaMinterStorage().assetInfos[asset].oracle).amountOf(amountIn, $.maxAge, Math.Rounding.Floor);
    }

    /**
     * @notice Returns the current coverage ratio.
     * @dev The coverage ratio would only be set to sub-1 in the event the amount of collateral collected wasnt enough
     * to fund all requests.
     */
    function latestCoverageRatio() public view returns (uint256) {
        return uint256(_getUSDaMinterStorage().coverageRatio.upperLookupRecent(clock()));
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
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
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
        USDaMinterStorage storage $ = _getUSDaMinterStorage();
        uint256[] storage userRequestsByAsset = $.redemptionRequestsByAsset[user][asset];
        RedemptionRequest[] storage userRequests = $.redemptionRequests[user];
        uint256 numRequests = userRequestsByAsset.length;
        uint256 i = $.firstUnclaimedIndex[user][asset];

        while (i < numRequests) {
            RedemptionRequest storage request =
                _unsafeRedemptionRequestByAssetAccess(userRequestsByAsset, userRequests, i);

            if (clock() >= request.claimableAfter) {
                uint256 amountClaimable;
                unchecked {
                    amountClaimable = request.amount * $.coverageRatio.upperLookupRecent(request.claimableAfter) / 1e18;
                }
                amount += amountClaimable;
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
     * @dev Internal function to handle the claiming of assets based on redemption requests. It processes multiple
     * redemption requests and manages the state of each request during the claim process.
     * This function is called during the public `claimTokens` function execution and ensures that claims are processed
     * in accordance with the set claimable timestamps and available amounts.
     * @param asset The address of the asset being claimed.
     * @param userRequests Array of all redemption requests made by the user.
     * @param userRequestsByAsset Array of redemption requests made by the user for the specific asset.
     * @param firstUnclaimedIndex Mapping of the first unclaimed index for quick access during claims.
     * @return amountRequested -> Amount of asset that was being requested in total.
     * @return amountBeingClaimed -> Amount of asset that is allowed to be claimed given coverage ratio.
     */
    function _claimTokens(
        address asset,
        RedemptionRequest[] storage userRequests,
        uint256[] storage userRequestsByAsset,
        mapping(address asset => uint256) storage firstUnclaimedIndex,
        Checkpoints.Trace208 storage ratio
    ) internal returns (uint256 amountRequested, uint256 amountBeingClaimed) {
        uint256 numRequests = userRequestsByAsset.length;
        uint256 i = firstUnclaimedIndex[asset];

        while (i < numRequests) {
            RedemptionRequest storage userRequest =
                _unsafeRedemptionRequestByAssetAccess(userRequestsByAsset, userRequests, i);
            if (clock() >= userRequest.claimableAfter) {
                unchecked {
                    uint256 amountClaimable = userRequest.amount * ratio.upperLookupRecent(userRequest.claimableAfter) / 1e18;
                    userRequest.claimed = amountClaimable;

                    amountRequested += userRequest.amount;
                    amountBeingClaimed += amountClaimable;

                    firstUnclaimedIndex[asset] = i + 1;
                }
            } else {
                break;
            }
            unchecked {
                ++i;
            }
        }

        return (amountRequested, amountBeingClaimed);
    }

    /**
     * @dev Transfers a specified amount of a supported asset from a user's address directly to this contract, adjusted
     * based on the redemption requirements. We assess the contract's balance before the transfer and after the transfer
     * to ensure the proper amount of tokens received is accounted. This comes in handy in the event a rebase rounding error
     * results in a slight deviation between amount transferred and the amount received.
     * @param user The address from which the asset will be pulled.
     * @param asset The address of the supported asset to be transferred.
     * @param amount The intended amount of the asset to transfer from the user. The function calculates the actual
     * transfer based on the asset’s pending redemption needs.
     * @return received The actual amount of the asset received to this contract, which may differ from
     * the intended amount due to transaction fees.
     * @custom:event CustodyTransfer Logs the transfer of the asset to this contract, detailing the amount and involved
     * parties.
     */
    function _pullAssets(address user, address asset, uint256 amount)
        internal
        returns (uint256 received)
    {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(user, address(this), amount);
        received = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        emit CustodyTransfer(address(this), asset, received);
    }

    /**
     * @dev Provides low-level, unchecked access to a specific redemption request within the user's array of requests.
     * This function is a critical component for manipulating redemption requests efficiently in storage.
     * It utilizes assembly to directly compute the storage slot of the requested index, bypassing Solidity's safety
     * checks. This method is used internally to update the state of redemption requests during the claiming process.
     * Care must be taken when using this function due to the lack of bounds checking; incorrect usage could lead to
     * undefined behavior or contract vulnerabilities.
     * @param userRequests The storage array containing the user's redemption requests.
     * @param pos The index of the redemption request within the array to access.
     * @return request A storage pointer to the `RedemptionRequest` at the specified index in the array.
     */
    function _unsafeRedemptionRequestAccess(RedemptionRequest[] storage userRequests, uint256 pos)
        internal
        pure
        returns (RedemptionRequest storage request)
    {
        assembly {
            mstore(0, userRequests.slot)
            request.slot := add(keccak256(0, 0x20), mul(pos, 3))
        }
    }

    /**
     * @dev Provides low-level, unchecked access to a specific redemption request within the user's array of redemption
     * requests by asset.
     * This function utilizes a low-level assembly technique to retrieve the index of the redemption request in the
     * global array of redemption requests, and then access the specific request using unchecked array indexing.
     * It is used to efficiently navigate through arrays without incurring the gas cost associated with bounds checking.
     * Care must be taken when using this function as it assumes that the provided position is within the valid range
     * and that the data integrity is maintained elsewhere in the contract logic. Improper use can lead to serious bugs
     * and security vulnerabilities.
     * @param userRequestsByAsset Array of uint256 containing indices of redemption requests for a specific asset.
     * @param userRequests Array of all redemption requests made by users.
     * @param pos Index in `userRequestsByAsset` pointing to the position in `userRequests`.
     * @return request Storage pointer to the `RedemptionRequest` corresponding to the index found in
     * `userRequestsByAsset` at position `pos`.
     */
    function _unsafeRedemptionRequestByAssetAccess(
        uint256[] storage userRequestsByAsset,
        RedemptionRequest[] storage userRequests,
        uint256 pos
    ) internal view returns (RedemptionRequest storage request) {
        StorageSlot.Uint256Slot storage slot = userRequestsByAsset.unsafeAccess(pos);
        request = _unsafeRedemptionRequestAccess(userRequests, slot.value);
    }
}
