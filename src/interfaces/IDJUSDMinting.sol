// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IDJUSDMintingEvents.sol";

interface IDJUSDMinting is IDJUSDMintingEvents {
    enum Role {
        Minter,
        Redeemer
    }

    enum OrderType {
        MINT,
        REQUEST,
        CLAIM
    }

    struct Route {
        address[] addresses;
        uint256[] ratios;
    }

    struct Order {
        OrderType order_type;
        uint256 expiry;
        uint256 nonce;
        address account;
        address collateral_asset;
        uint256 collateral_amount;
    }

    error Duplicate();
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
    error InvalidNonce();
    error SignatureExpired();
    error TransferFailed();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
    error InvalidAmountReceived();
    error NoAssetsClaimable();
    error LowLevelCallFailed();

    function verifyOrder(Order calldata order) external view returns (bool);

    function verifyRoute(Route calldata route, OrderType order_type) external view returns (bool);

    function verifyNonce(address sender, uint256 nonce) external view returns (bool, uint256, uint256, uint256);

    function mint(Order calldata order, Route calldata route) external;

    function requestRedeem(Order calldata order) external;
}
