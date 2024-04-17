// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle} from "../../src/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    using Math for uint256;

    uint256 public constant PRICE_PRECISION = 1e18;

    address public immutable token;

    bool private immutable _scaleUp;
    uint256 private immutable _scalePrecision;
    uint256 private immutable _tokenPrecision;
    uint256 private immutable _staticPrice;

    /**
     * @notice Constructs the StaticPriceOracle contract.
     * @dev Initializes the contract with a fixed price for the token and adjusts the price precision if necessary.
     * @param _token The address of the token for which the static price is set.
     * @param staticPrice The static price for the token.
     * @param decimals The number of decimals for the price.
     */
    constructor(address _token, uint256 staticPrice, uint8 decimals) {
        token = _token;
        _tokenPrecision = 10 ** IERC20Metadata(_token).decimals();
        uint256 pricePrecision = 10 ** decimals;
        require(pricePrecision <= PRICE_PRECISION, "MockOracle: too many decimals");
        bool scaleUp = pricePrecision < PRICE_PRECISION;
        _scaleUp = scaleUp;
        _scalePrecision = scaleUp ? PRICE_PRECISION / pricePrecision : 1;
        _staticPrice = staticPrice * _scalePrecision;
    }

    /**
     * @notice Converts a value in the oracle's quote currency to an amount of the token.
     * @dev Calculates the amount of token equivalent to the given value based on the static price.
     * @param value The value to convert.
     * @param rounding The rounding direction (up or down).
     * @return amount The calculated amount of the token.
     */
    function amountOf(uint256 value, Math.Rounding rounding) external view returns (uint256 amount) {
        amount = value.mulDiv(_tokenPrecision, _latestPrice(), rounding);
    }

    /**
     * @notice Converts a value in the oracle's quote currency to an amount of the token at a specific price, applying a
     *         specified rounding method.
     * @dev Calculates the equivalent amount of the oracle's asset for a given value using a specified price, unlike
     *      `amountOf` which uses the latest price.
     * @param value The value in the base currency to be converted.
     * @param price The specific price to use for the conversion.
     * @param rounding The rounding method to be used (up, down, or closest).
     * @return amount The calculated amount in the oracle's asset at the specified price.
     */
    function amountOfAtPrice(uint256 value, uint256 price, Math.Rounding rounding)
        external
        view
        returns (uint256 amount)
    {
        amount = value.mulDiv(_tokenPrecision, price, rounding);
    }

    /**
     * @notice Retrieves the latest static price of the token.
     * @dev Returns the constant price set for the token.
     * @return price The static price of the token.
     */
    function latestPrice() external view returns (uint256 price) {
        (price,) = _priceInfo();
    }

    /**
     * @notice Retrieves the latest static price of the token, validating against a maximum age.
     * @dev Returns the constant price set for the token and ensures it is not older than `maxAge`.
     * @return price The static price of the token.
     */
    function latestPrice(uint256) external view returns (uint256 price) {
        uint256 age;
        (price, age) = _priceInfo();
    }

    /**
     * @notice Calculates the value of a token amount in the oracle's quote currency.
     * @dev Computes the value based on the static price of the token.
     * @param amount The amount of the token.
     * @param rounding The rounding direction (up or down).
     * @return value The calculated value in the quote currency.
     */
    function valueOf(uint256 amount, Math.Rounding rounding) external view returns (uint256 value) {
        value = _valueOf(amount, _latestPrice(), rounding);
    }

    /**
     * @notice Converts an amount in the oracle's asset to a value in the base currency at a specific price, applying a
     *         specified rounding method.
     * @dev Calculates the equivalent value in the base currency for a given amount of the oracle's asset using a
     *      specified price, as opposed to `valueOf` which uses the latest price.
     * @param amount The amount of the oracle's asset to be converted.
     * @param price The specific price to use for the conversion.
     * @param rounding The rounding method to be used (up, down, or closest).
     * @return value The calculated value in the base currency at the specified price.
     */
    function valueOfAtPrice(uint256 amount, uint256 price, Math.Rounding rounding)
        external
        view
        returns (uint256 value)
    {
        value = _valueOf(amount, price, rounding);
    }

    /**
     * @notice Internal function to calculate the value of a given amount of the token.
     * @dev Calculates the value based on the provided token amount and price.
     * @param amount The amount of the token.
     * @param price The price of the token.
     * @param rounding The rounding direction (up or down).
     * @return value The calculated value of the token amount.
     */
    function _valueOf(uint256 amount, uint256 price, Math.Rounding rounding) internal view returns (uint256 value) {
        value = amount.mulDiv(price, _tokenPrecision, rounding);
    }

    /**
     * @notice Internal function to retrieve the latest static price of the token.
     * @dev Returns the constant price set for the token.
     * @return price The static price of the token.
     */
    function _latestPrice() internal view returns (uint256 price) {
        (price,) = _priceInfo();
    }

    /**
     * @notice Internal function to get the price information, including price and age.
     * @dev Returns the static price and a simulated age of the price, which is always zero.
     * @return price The static price of the token.
     * @return age The simulated age of the price, always zero for static prices.
     */
    function _priceInfo() private view returns (uint256 price, uint256 age) {
        return (_staticPrice, 0);
    }
}
