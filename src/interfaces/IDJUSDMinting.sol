// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IDJUSDMintingEvents.sol";

interface IDJUSDMinting is IDJUSDMintingEvents {
    enum Role {
        Minter,
        Redeemer
    }

    struct Route {
        address[] addresses;
        uint256[] ratios;
    }

    struct Order {
        uint256 expiry;
        address collateral_asset;
        uint256 collateral_amount;
    }

    error InvalidAddress();
    error InvalidZeroAddress();
    error InvalidAssetAddress();
    error InvalidCustodianAddress();
    error InvalidOrder();
    error InvalidAffirmedAmount();
    error InvalidAmount();
    error InvalidRoute();
    error UnsupportedAsset();
    error InvalidSignature();
    error SignatureExpired();
    error TransferFailed();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
    error InvalidAmountReceived();
    error NoAssetsClaimable();
    error LowLevelCallFailed();

    function verifyOrder(Order calldata order) external view returns (bool);

    function verifyRoute(Route calldata route) external view returns (bool);

    function mint(Order calldata order, Route calldata route) external;

    function requestRedeem(Order calldata order) external;
}
