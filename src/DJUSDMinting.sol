// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { Checkpoints } from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

// local imports
import { IDJUSD } from "./interfaces/IDJUSD.sol";
import { IDJUSDMinting } from "./interfaces/IDJUSDMinting.sol";

/**
 * @title Djinn Minting
 * @notice This contract mints and redeems DJUSD in a single, atomic, trustless transaction
 */
contract DJUSDMinting is UUPSUpgradeable, IDJUSDMinting, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Checkpoints for Checkpoints.Trace208;

    // ---------------
    // State Variables
    // ---------------

    /// @dev route type
    bytes32 private constant ROUTE_TYPE = keccak256("Route(address[] addresses,uint256[] ratios)");
    /// @dev djusd stablecoin
    IDJUSD public djusd;
    /// @dev Supported assets
    EnumerableSet.AddressSet internal _supportedAssets;
    /// @dev custodian addresses
    EnumerableSet.AddressSet internal _custodianAddresses;
    /// @dev Stores the total amount of `asset` that has been requested using checkpoints.
    mapping(address asset => Checkpoints.Trace208) internal totalRequestCheckpoints;
    /// @dev Returns the total amount of `asset` that has been claimed.
    mapping(address asset => uint256) public totalClaimed;
    /// @dev Tracks the total amount of an `asset` requested to claim by an `account`.
    mapping(address account => mapping(address asset => Checkpoints.Trace208)) internal accountRequestCheckpoints;
    /// @dev Tracks the total amount of an `asset` that has been claimed by an `account`.
    mapping(address account => mapping(address asset => uint256 amountClaimed)) public claimed;
    /// @dev Stores the minimum amount of seconds between asset request and asset claim.
    uint48 public claimDelay;


    // -----------
    // Constructor
    // -----------

    constructor() {
        _disableInitializers();
    }


    // -----------
    // Initializer
    // -----------

    /**
     * @notice Initializes this contract
     * @param _djusd DJUSD Contract address
     * @param _assets Array of ERC20 stablecoins that will be used as collateral for DJUSD
     * @param _custodians Array of addresses in which collateral is deposited
     * @param _admin Initial owner of this contract
     */
    function initialize(
        IDJUSD _djusd,
        address[] memory _assets,
        address[] memory _custodians,
        address _admin
    ) external initializer {
        if (address(_djusd) == address(0)) revert InvalidZeroAddress();
        if (_assets.length == 0) revert InvalidZeroAddress();
        if (_admin == address(0)) revert InvalidZeroAddress();

        claimDelay = uint48(5 days);
        djusd = _djusd;

        __Ownable2Step_init();
        __Ownable_init(_admin);

        for (uint256 i; i < _assets.length;) {
            _addSupportedAsset(_assets[i]);
            unchecked {
                ++i;
            }
        }

        for (uint256 i; i < _custodians.length;) {
            _addCustodianAddress(_custodians[i]);
            unchecked {
                ++i;
            }
        }
    }


    // ----------------
    // External Methods
    // ----------------

    /**
    * @notice Mint DJUSD from assets
    * @param order struct containing order details
    */
    function mint(Order calldata order, Route calldata route) external override nonReentrant {
        verifyOrder(order);
        if (!verifyRoute(route)) revert InvalidRoute();

        // transfer asset from minter to this contract
        uint256 received = _transferCollateral(
            order.collateral_amount, order.collateral_asset, msg.sender, route.addresses, route.ratios
        );
        
        djusd.mint(msg.sender, received);
        emit Mint(msg.sender, order.collateral_asset, received);
    }

    /**
    * @notice Request to redeem stablecoins for assets
    * @param order struct containing order details
    */
    function requestRedeem(Order calldata order) external override nonReentrant {
        verifyOrder(order);        

        // burn DJUSD
        djusd.burnFrom(msg.sender, order.collateral_amount);

        uint48 timepoint = uint48(clock());
        // update account
        uint256 allTimeRequested = _accountRequestCheckpointsLookup(msg.sender, order.collateral_asset, timepoint, 0);
        accountRequestCheckpoints[msg.sender][order.collateral_asset].push(timepoint, uint208(allTimeRequested + order.collateral_amount));
        // update total
        uint256 totalAllTimeRequestedForAsset = _totalRequestCheckpointsLookup(order.collateral_asset, timepoint, 0);
        totalRequestCheckpoints[order.collateral_asset].push(timepoint, uint208(totalAllTimeRequestedForAsset + order.collateral_amount));

        emit RedeemRequested(
            msg.sender,
            order.collateral_asset,
            order.collateral_amount
        );
    }

    /**
    * @notice Claim stablecoins that were requested previously
    * @param order struct containing order details
    */
    function claim(Order calldata order) external nonReentrant {
        verifyOrder(order);

        uint256 amountClaimable = getClaimableForAccount(msg.sender, order.collateral_asset);
        if (amountClaimable == 0) revert NoAssetsClaimable();
        if (order.collateral_amount > amountClaimable) revert InvalidAmount();

        _transferToBeneficiary(msg.sender, order.collateral_asset, order.collateral_amount);

        // Update claimed for msg.sender
        claimed[msg.sender][order.collateral_asset] += order.collateral_amount;
        // Update total claimed
        totalClaimed[order.collateral_asset] += order.collateral_amount;

        emit AssetsClaimed(
            msg.sender,
            order.collateral_asset,
            order.collateral_amount
        );
    }

    function setClaimDelay(uint48 _delayInSeconds) external onlyOwner {
        emit ClaimDelayUpdated(claimDelay, _delayInSeconds);
        claimDelay = _delayInSeconds;
    }

    /// @notice transfers an asset to a custody wallet
    function transferToCustody(address wallet, address asset, uint256 amount) external nonReentrant onlyOwner {
        if (wallet == address(0) || !_custodianAddresses.contains(wallet)) revert InvalidAddress();
        emit CustodyTransfer(wallet, asset, amount);
        IERC20(asset).safeTransfer(wallet, amount);
    }

    /// @notice Checks if an asset is supported.
    function isSupportedAsset(address asset) external view returns (bool) {
        return _supportedAssets.contains(asset);
    }

    /// @notice Adds an asset to the supported assets list.
    function addSupportedAsset(address asset) external onlyOwner {
        _addSupportedAsset(asset);
    }

    /// @notice Opts out of rebase of `asset`.
    /// @dev Will only opt out of supported assets.
    function optOutOfRebase(address asset, bool optOut) external onlyOwner {
        if (!_supportedAssets.contains(asset)) revert InvalidAssetAddress();
        bytes memory data = abi.encodeWithSignature("disableRebase(address,bool)", address(this), optOut);
        (bool success,) = asset.call(data);
        if (!success) revert LowLevelCallFailed();
    }

    /// @notice Removes an asset from the supported assets list
    function removeSupportedAsset(address asset) external onlyOwner {
        if (!_supportedAssets.remove(asset)) revert InvalidAssetAddress();
        emit AssetRemoved(asset);
    }

    /// @notice Checks if an address is a supported custodian.
    function isCustodianAddress(address custodian) external view returns (bool) {
        return _custodianAddresses.contains(custodian);
    }

    /// @notice Adds an custodian to the supported custodians list.
    function addCustodianAddress(address custodian) external onlyOwner {
        _addCustodianAddress(custodian);
    }

    /// @notice Removes an custodian from the custodian address list
    function removeCustodianAddress(address custodian) external onlyOwner {
        if (!_custodianAddresses.remove(custodian)) revert InvalidCustodianAddress();
        emit CustodianAddressRemoved(custodian);
    }

    /// @notice This method allows for a manual upperLookup on the `accountRequestCheckpoints` mapped checkpoints array.
    /// @dev This method does NOT return the amount that has been claimed. This method will only return the total amount the `account` has requested
    ///      of `asset` at the specified `timepoint`.
    function accountRequestCheckpointsManualLookup(address account, address asset, uint48 timepoint) external view returns (uint256 totalRequested) {
        totalRequested = _accountRequestCheckpointsLookup(account, asset, timepoint, 0);
    }

    /// @notice This method allows for a manual upperLookup on the `totalRequestCheckpoints` mapped checkpoints array.
    /// @dev This method does NOT return the amount that has been claimed. This method will only return the total amount requested
    ///      of `asset` at the specified `timepoint`.
    function totalRequestCheckpointsForAssetManualLookup(address asset, uint48 timepoint) external view returns (uint256 totalRequested) {
        totalRequested = _totalRequestCheckpointsLookup(asset, timepoint, 0);
    }

    /// @notice This method allows for a manual upperLookup on the `totalRequestCheckpoints` mapped checkpoints array for every asset
    ///         this contract supports. If there are 3 assets, it will do a lookup on all 3 assets and return the total amount requested as of
    ///         the specified `timepoint`.
    /// @dev This method does NOT return the amount that has been claimed. This method will only return the total amount requested
    ///      of `asset` at the specified `timepoint`.
    function totalRequestCheckpointsManualLookup(uint48 timepoint) external view returns (uint256 totalRequested) {
        address[] memory assets = getAllSupportedAssets();
        uint256 len = assets.length;

        for (uint256 i; i < len;) {
            totalRequested += _totalRequestCheckpointsLookup(assets[i], timepoint, 0);
            unchecked {
                ++i;
            }
        }
    }

    
    // --------------
    // Public Methods
    // --------------

    /// @notice Returns all addresses within the `_supportedAssets` set.
    function getAllSupportedAssets() public view returns (address[] memory) {
        return _supportedAssets.values();
    }

    /// @notice Returns all addresses within the `_custodianAddresses` set.
    function getAllCustodians() public view returns (address[] memory) {
        return _custodianAddresses.values();
    }

    /// @notice Returns the total amount claimable for an account, given the asset being claimed.
    function getClaimableForAccount(address account, address asset) public view returns (uint256) {
        if (!_supportedAssets.contains(asset) || account == address(0)) return 0;
        uint48 timepoint = clock();

        uint256 claimable = _accountRequestCheckpointsLookup(account, asset, timepoint, claimDelay) - claimed[account][asset];
        return claimable;
    }

    /// @notice Returns the total amount claimable, given the asset.
    function getTotalClaimableForAsset(address asset) public view returns (uint256) {
        if (!_supportedAssets.contains(asset)) return 0;
        uint48 timepoint = clock();

        uint256 totalClaimable = _totalRequestCheckpointsLookup(asset, timepoint, claimDelay) - totalClaimed[asset];
        return totalClaimable;
    }

    /// @notice In the event this contract has multiple assets within `_supportedAssets`. This view
    /// nethod will be needed to fetch the total amount of stable assets that are claimable.
    function getTotalClaimable() public view returns (uint256 claimable) {
        uint48 timepoint = clock();
        address[] memory assets = getAllSupportedAssets();
        uint256 len = assets.length;

        for (uint256 i; i < len;) {
            claimable += (_totalRequestCheckpointsLookup(assets[i], timepoint, claimDelay) - totalClaimed[assets[i]]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Encodes the route provided and returns it as a bytes array.
    function encodeRoute(Route calldata route) public pure returns (bytes memory) {
        return abi.encode(ROUTE_TYPE, route.addresses, route.ratios);
    }

    /// @notice assert validity of signed order
    function verifyOrder(Order calldata order) public view override returns (bool) {
        if (order.collateral_amount == 0) revert InvalidAmount();
        if (block.timestamp > order.expiry) revert SignatureExpired();
        return (true);
    }

    /// @notice assert validity of route object per type
    function verifyRoute(Route calldata route) public view override returns (bool) {
        uint256 totalRatio = 0;
        if (route.addresses.length != route.ratios.length) {
            return false;
        }
        if (route.addresses.length == 0) {
            return false;
        }
        for (uint256 i; i < route.addresses.length;) {
            if (!_custodianAddresses.contains(route.addresses[i]) || route.addresses[i] == address(0) || route.ratios[i] == 0) {
                return false;
            }
            totalRatio += route.ratios[i];
            unchecked {
                ++i;
            }
        }
        if (totalRatio != 10_000) {
            return false;
        }
        return true;
    }

    /**
     * @notice Returns the current block.timestamp.
     */
    function clock() public view virtual returns (uint48) {
        return Time.timestamp();
    }

    /**
     * @dev Machine-readable description of the clock as specified in EIP-6372.
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure virtual returns (string memory) {
        return "mode=timestamp";
    }

    
    // ----------------
    // Internal Methods
    // ----------------

    /// @notice Uses Checkpoints.upperLookup to fetch the last amount requested for redemption.
    /// @dev Does take into account a delay in the event we wanted to query claimable.
    function _accountRequestCheckpointsLookup(address account, address asset, uint48 timepoint, uint48 delay) internal view returns (uint256) {
        return uint256(accountRequestCheckpoints[account][asset].upperLookup(timepoint - delay));
    }

    /// @notice Uses Checkpoints.upperLookup to fetch the last amount requested for redemption.
    /// @dev Does take into account a delay in the event we wanted to query claimable.
    function _totalRequestCheckpointsLookup(address asset, uint48 timepoint, uint48 delay) internal view returns (uint256) {
        return uint256(totalRequestCheckpoints[asset].upperLookup(timepoint - delay));
    }

    /// @notice Adds an asset to the supported assets list.
    function _addSupportedAsset(address asset) internal {
        if (asset == address(0) || asset == address(djusd) || !_supportedAssets.add(asset)) {
            revert InvalidAssetAddress();
        }
        emit AssetAdded(asset);
    }

    /// @notice Adds an custodian to the supported custodians list.
    function _addCustodianAddress(address custodian) internal {
        if (custodian == address(0) || custodian == address(djusd) || !_custodianAddresses.add(custodian)) {
            revert InvalidCustodianAddress();
        }
        emit CustodianAddressAdded(custodian);
    }

    /// @notice transfer supported asset to beneficiary address
    function _transferToBeneficiary(address beneficiary, address asset, uint256 amount) internal {
        if (!_supportedAssets.contains(asset)) revert UnsupportedAsset();
        IERC20(asset).safeTransfer(beneficiary, amount);
    }

    /// @notice transfer supported asset to array of custody addresses per defined ratio
    function _transferCollateral(
        uint256 amount,
        address asset,
        address account,
        address[] calldata addresses,
        uint256[] calldata ratios
    ) internal returns (uint256 received) {
        // cannot mint using unsupported asset or native ETH even if it is supported for redemptions
        if (!_supportedAssets.contains(asset)) revert UnsupportedAsset();
        IERC20 token = IERC20(asset);

        uint256 preBal = token.balanceOf(address(this));
        token.transferFrom(account, address(this), amount);
        received = token.balanceOf(address(this)) - preBal;

        if (received == 0) revert InvalidAmountReceived();

        uint256 totalTransferred = 0;
        for (uint256 i; i < addresses.length;) { // TODO: Test
            uint256 amountToTransfer = (received * ratios[i]) / 10_000;
            token.transfer(addresses[i], amountToTransfer);
            totalTransferred += amountToTransfer;
            unchecked {
                ++i;
            }
        }
        uint256 remainingBalance = received - totalTransferred;
        if (remainingBalance != 0) {
            token.transfer(addresses[addresses.length - 1], remainingBalance);
        }
    }

    /**
     * @notice Overriden from UUPSUpgradeable
     * @dev Restricts ability to upgrade contract to `DEFAULT_ADMIN_ROLE`
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
