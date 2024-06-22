// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// aerodrome imports
import {IRouter} from "@aero/contracts/interfaces/IRouter.sol";
import {IVoter} from "@aero/contracts/interfaces/IVoter.sol";
import {IGauge} from "@aero/contracts/interfaces/IGauge.sol";

// local
import {CommonErrors} from "./interfaces/CommonErrors.sol";
import {CommonValidations} from "./libraries/CommonValidations.sol";

/**
 * @title AeroLooper
 * @notice This contract is in charge of managing liquidity positions and emissions on Aerodrome.
 */
contract AeroLooper is UUPSUpgradeable, CommonErrors, OwnableUpgradeable {
    using CommonValidations for *;
    using SafeERC20 for IERC20;

    // TODO: Collect ETH
    // TODO: Gelato Func will check ETH balance of contract and inject it into an ETH/USDC liquidity
    //      - Once injected, LP tokens have to be staked for emissions
    // TODO: If there's claimable emissions; claim those emissions, sell emissions, and re-inject into pool, stake LP tokens

    /// @dev Stores contract reference to Aerodrome Router.
    IRouter public immutable AERO_ROUTER;
    /// @dev Stores contract reference to Aerodrome Voter.
    IVoter public immutable AERO_VOTER;
    /// @dev Stores contract reference to Aerdrome Gauge for pool.
    IGauge public immutable GAUGE;
    /// @dev Stores address for WETH.
    address public immutable WETH;
    /// @dev Stores address for ERC-20 token which serves as underlying in pool.
    address public immutable UNDERLYING;
    /// @dev Stores address of Aerodrome pool.
    address public immutable POOL;
    /// @dev Used to add a small deviation of the minimum amount of tokens used when adding liquidity.
    uint256 public slippage;


    // ---------------
    // Events & Errors
    // ---------------

    event LiquidityInjected(uint256 amountETH, uint256 amountUnderlying, uint256 liquidityReceived);
    event LiquidityStaked(uint256 amount);
    event FundsWithdrawn(address token, uint256 amount);
    event GaugeWithdrawn(uint256 amount, uint256 stillInBalance);
    event SlippageUpdated(uint256 newSlippage);

    error InsufficientLiquidityReceived(uint256 received, uint256 expected);
    error ETHWithdrawFailed();
    error AmountExceedsWithdrawable(uint256 withdrawable);


    // ----------
    // Initialize
    // ----------

    /**
     * @notice Initializes AeroLooper
     * @param _aeroRouter Address of Aerodrome Router contract.
     * @param _underlying Address of underlying token of pool.
     */
    constructor(address _aeroRouter, address _underlying) {
        _aeroRouter.requireNonZeroAddress();
        _underlying.requireNonZeroAddress();

        AERO_ROUTER = IRouter(_aeroRouter);
        AERO_VOTER = IVoter(AERO_ROUTER.voter());
        WETH = address(AERO_ROUTER.weth());

        (address token0, address token1) = WETH < _underlying ? 
            (WETH, _underlying) : (_underlying, WETH);
        POOL = AERO_ROUTER.poolFor(
            token0,
            token1,
            false,
            AERO_ROUTER.defaultFactory()
        );

        GAUGE = IGauge(AERO_VOTER.gauges(POOL));
        UNDERLYING = _underlying;

        _disableInitializers();
    }

    /**
     * @notice Initializer for proxy
     * @dev Will assign the owner and default slippage for proxy.
     */
    function initialize() external initializer {
        __Ownable_init(msg.sender);
        slippage = 10; // 1% slippage by default
    }


    // ----------------
    // External Methods
    // ----------------

    receive() external payable {}

    /**
     * @notice This method injects liquidity into the `pool`.
     * @dev amounts specified should take into account pool ratio. Once liquidity is injected, 
     * the LP tokens will be deposited into the proper gauge to begin emissions.
     * This method can be used in tangent with quoteAddLiquidity to identify params.
     *
     * @param amountETH Amount of ETH to be injected into liquidity.
     * @param amountUnderlying Amount of underlying token to be injected into liquidity.
     * @param expectedLiquidity Amount of expected liquidity tokens to receive post-addLiquidity.
     * @param deadline Desired block.timestamp deadline of liquidity add.
     */
    function injectLiquidity(
        uint256 amountETH, 
        uint256 amountUnderlying,
        uint256 expectedLiquidity,
        uint256 deadline
    ) external onlyOwner {
        uint256 amountLPTokens = _injectLiquidity(
            amountETH,
            amountUnderlying,
            expectedLiquidity,
            deadline
        );
        _stakeLPTokens(amountLPTokens);
    }

    /**
     * @notice TODO
     * @dev TODO
     */
    function claimAndStakeEmissions() external onlyOwner returns (uint256) {
        // TODO claim emissions
        GAUGE.getReward(address(this));
        // TODO swap emissions for ETH and USDC
        //      take into account ETH/USDC ratio and amount of ETH+USDC dust in contract

        // TODO stake LP tokens
    }

    /**
     * @notice This permissioned external method allows the owner to update the slippage variable.
     * @dev The slippage is used to calculate amount of minimum slippage is allowed when injecting liquidity.
     * By default this variable is 10 which is 1% slippage. If we're adding 100 ETH into the pool, the 1% slippage
     * will calculate the minimum taken by the pool as 99 ETH. Nothing less is allowed.
     *
     * @param newSlippage New variable to be assigned as slippage. Must be less than 1001.
     */
    function setSlippage(uint256 newSlippage) external onlyOwner {
        newSlippage.requireLessThanOrEqualToUint256(1000);
        emit SlippageUpdated(newSlippage);
        slippage = newSlippage;
    }

    /**
     * @notice This permissioned external method allows the owner to withdraw the staked liquidity tokens that
     * are inside the Gauge contract.
     * @param amount Amount of lp tokens to withdraw from the Gauge contract.
     */
    function withdrawFromGauge(uint256 amount) external onlyOwner {
        uint256 balance = GAUGE.balanceOf(address(this));
        if (amount > balance) revert AmountExceedsWithdrawable(balance);
        emit GaugeWithdrawn(amount, balance - amount);
        GAUGE.withdraw(amount);
        IERC20(POOL).safeTransfer(owner(), amount);
    }

    /**
     * @notice This permissioned external method allows the owner to withdraw ETH from this contract.
     * @param amount Amount of ETH to withdraw.
     */
    function withdrawETH(uint256 amount) external onlyOwner {
        amount.requireLessThanOrEqualToUint256(address(this).balance);
        emit FundsWithdrawn(address(0), amount);
        (bool success,) = owner().call{value:amount}("");
        if (!success) revert ETHWithdrawFailed();
    }

    /**
     * @notice This permissioned external method allows the owner to withdraw ERC20 tokens from this contract.
     * @param token Contract address of ERC20 token that's being withdrawn.
     * @param amount Amount of ERC20 tokens to withdraw.
     */
    function withdrawERC20(address token, uint256 amount) external onlyOwner {
        amount.requireLessThanOrEqualToUint256(IERC20(token).balanceOf(address(this)));
        token.requireNonZeroAddress();
        emit FundsWithdrawn(token, amount);
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @notice Returns the amount of claimable rewards in the Gauge contract.
     */
    function claimableRewards() external view returns (uint256) {
        return GAUGE.rewards(address(this));
    }

    /**
     * @notice This method is used to get a quote for adding liquidity to the pool. The method takes an amount of ETH
     * and an amount of underlying token and will return the amount that will be taken into the pool (based on the current
     * ratio) and the amount of lp tokens that will be minted for that liquidity.
     * @dev This method should be called before executing injectLiquidity.
     * 
     * @param amountETHDesired The desired amount of ETH we want to allocate towards liquidity.
     * @param amountUnderlyingDesired The desired amount of underlying tokens we want to allocate towards liquidity.
     *
     * @return amountETH The amount of ETH that would be accepted into the pool based on current reserves ratio.
     * @return amountUnderlying The amount of underlying tokens that would be accepted into the pool based on current
     * reserves ratio.
     * @return liquidity Amount of liquidity pool tokens that would be minted for the liqudity provided.
     */
    function quoteAddLiquidity(
        uint256 amountETHDesired,
        uint256 amountUnderlyingDesired
    ) external view returns (uint256 amountETH, uint256 amountUnderlying, uint256 liquidity) {
        (address token0, address token1) = WETH < UNDERLYING ? (WETH, UNDERLYING) : (UNDERLYING, WETH);
        (uint256 amount0, uint256 amount1) = token0 == WETH ?
            (amountETHDesired, amountUnderlyingDesired) : (amountUnderlyingDesired, amountETHDesired);
        
        (uint256 amountA, uint256 amountB, uint256 liq) = AERO_ROUTER.quoteAddLiquidity(
            token0,
            token1,
            false,
            IRouter(AERO_ROUTER).defaultFactory(),
            amount0,
            amount1
        );

        (amountETH, amountUnderlying) = token0 == WETH ?
            (amountA, amountB) : (amountB, amountA);

        return (amountETH, amountUnderlying, liq);
    }


    // ----------------
    // Internal Methods
    // ----------------

    function _injectLiquidity(
        uint256 amountETH, 
        uint256 amountUnderlying,
        uint256 expectedLiquidity,
        uint256 deadline
    ) internal returns (uint256 liquidity) {
        IERC20(UNDERLYING).approve(address(AERO_ROUTER), amountUnderlying);
        (,,liquidity) = AERO_ROUTER.addLiquidityETH{value:amountETH}(
            UNDERLYING, // underlying
            false, // stable
            amountUnderlying, // amountTokenDesired
            amountUnderlying-(amountUnderlying*slippage/1000), // amountTokenMin
            amountETH-(amountETH*slippage/1000), // amountETHMin
            address(this), // to
            deadline // deadline
        );
        if (liquidity != expectedLiquidity) {
            revert InsufficientLiquidityReceived(liquidity, expectedLiquidity);
        }
        emit LiquidityInjected(amountETH, amountUnderlying, liquidity);
    }

    function _stakeLPTokens(uint256 amount) internal {
        IERC20(POOL).approve(address(GAUGE), amount);
        GAUGE.deposit(amount);
    }

    function _sellEmissions() internal returns (uint256 amountEth, uint256 amountUnderlying) {
        // TODO: Get ratio
        (uint256 amount0, uint256 amount1) = AERO_ROUTER.getReserves(WETH, UNDERLYING, false, AERO_ROUTER.defaultFactory());
        // TODO: Sell for ETH
        // TODO: Sell for USDC
    }

    function _claimEmissions() internal returns (uint256) {}

    /**
     * @notice Overriden from UUPSUpgradeable
     * @dev Restricts ability to upgrade contract to owner
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

}