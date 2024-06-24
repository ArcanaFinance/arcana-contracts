// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

// oz imports
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// aerodrome imports
import {IRouter} from "@aero/contracts/interfaces/IRouter.sol";
import {IPool} from "@aero/contracts/interfaces/IPool.sol";
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

    /// @dev AERO token address.
    IERC20 public constant AERO = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    /// @dev Stores contract reference to Aerodrome Router.
    IRouter public immutable AERO_ROUTER;
    /// @dev Stores contract reference to Aerodrome Voter.
    IVoter public immutable AERO_VOTER;
    /// @dev Stores contract reference to Aerdrome Gauge for pool.
    IGauge public immutable GAUGE;
    /// @dev Stores address for WETH.
    address public immutable WETH;
    /// @dev Stores address for ERC-20 token which serves as underlying in pool.
    //address public immutable UNDERLYING;
    /// @dev Stores address of Aerodrome pool.
    address public immutable POOL;
    /// @dev Used to add a small deviation of the minimum amount of tokens used when adding liquidity.
    uint256 public slippage;

    address public immutable TOKEN0;
    address public immutable TOKEN1;


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
     * @param _pool Address of desired pool.
     */
    constructor(address _aeroRouter, address _pool) {
        _aeroRouter.requireNonZeroAddress();
        _pool.requireNonZeroAddress();

        AERO_ROUTER = IRouter(_aeroRouter);
        AERO_VOTER = IVoter(AERO_ROUTER.voter());
        WETH = address(AERO_ROUTER.weth());

        TOKEN0 = IPool(_pool).token0();
        TOKEN1 = IPool(_pool).token1();

        // (address token0, address token1) = WETH < _underlying ? 
        //     (WETH, _underlying) : (_underlying, WETH);
        // POOL = AERO_ROUTER.poolFor(
        //     token0,
        //     token1,
        //     false,
        //     AERO_ROUTER.defaultFactory()
        // );

        GAUGE = IGauge(AERO_VOTER.gauges(_pool));
        POOL = _pool;

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

    /// @dev Allows this contract to receive Ether.
    receive() external payable {}

    /**
     * @notice This method injects liquidity into the `pool`.
     * @dev amounts specified should take into account pool ratio. Once liquidity is injected, 
     * the LP tokens will be deposited into the proper gauge to begin emissions.
     * This method can be used in tangent with quoteAddLiquidity to identify params.
     *
     * @param amountToken0 Amount of TOKEN0 to be injected into liquidity.
     * @param amountToken1 Amount of TOKEN1 token to be injected into liquidity.
     * @param expectedLiquidity Amount of expected liquidity tokens to receive post-addLiquidity.
     * @param deadline Desired block.timestamp deadline of liquidity add.
     */
    function injectLiquidity(
        uint256 amountToken0, 
        uint256 amountToken1,
        uint256 expectedLiquidity,
        uint256 deadline
    ) external onlyOwner {
        uint256 amountLPTokens = _injectLiquidity(
            amountToken0,
            amountToken1,
            expectedLiquidity,
            deadline
        );
        _stakeLPTokens(amountLPTokens);
    }

    /**
     * @notice This permissioned method allows the owner to claim and stake any emissions from the Gauge.
     * @dev This contract will claim any claimable AERO from the Gauge and use that to inject more liquidity
     * into the pool. First, the contract has to sell the AERO for TOKEN0 and TOKEN1. The amount that it sells is
     * dependant on the current TOKEN0/TOKEN1 ratio in the pool. This method also takes into account the current
     * contract balance of TOKEN0 and TOKEN1 to avoid any collection of dust and thus any unused liquidity.
     */
    function claimAndStakeEmissions() external onlyOwner {
        // TODO claim emissions
        require(claimableRewards() != 0);
        GAUGE.getReward(address(this));
        // TODO swap emissions for TOKEN0 and USDC
        //      take into account TOKEN0/USDC ratio and amount of TOKEN0+USDC dust in contract
        uint256 balance = AERO.balanceOf(address(this));
        _sellEmissions(balance);
        // TODO stake LP tokens
    }

    /**
     * @notice This permissioned external method allows the owner to update the slippage variable.
     * @dev The slippage is used to calculate amount of minimum slippage is allowed when injecting liquidity.
     * By default this variable is 10 which is 1% slippage. If we're adding 100 TOKEN0 into the pool, the 1% slippage
     * will calculate the minimum taken by the pool as 99 TOKEN0. Nothing less is allowed.
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
     * @notice This permissioned external method allows the owner to withdraw TOKEN0 from this contract.
     * @param amount Amount of TOKEN0 to withdraw.
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
    function claimableRewards() public view returns (uint256) {
        return GAUGE.rewards(address(this));
    }

    /**
     * @notice This method is used to get a quote for adding liquidity to the pool. The method takes an amount of TOKEN0
     * and an amount of TOKEN1 token and will return the amount that will be taken into the pool (based on the current
     * ratio) and the amount of lp tokens that will be minted for that liquidity.
     * @dev This method should be called before executing injectLiquidity.
     * 
     * @param amountToken0 The desired amount of TOKEN0 we want to allocate towards liquidity.
     * @param amountToken1 The desired amount of TOKEN1 we want to allocate towards liquidity.
     *
     * @return amount0 The amount of TOKEN0 that would be accepted into the pool based on current reserves ratio.
     * @return amount1 The amount of TOKEN1 that would be accepted into the pool based on current
     * reserves ratio.
     * @return liquidity Amount of liquidity pool tokens that would be minted for the liqudity provided.
     */
    function quoteAddLiquidity(
        uint256 amountToken0,
        uint256 amountToken1
    ) external view returns (uint256 amount0, uint256 amount1, uint256 liquidity) {        
        (amount0, amount1, liquidity) = AERO_ROUTER.quoteAddLiquidity(
            TOKEN0,
            TOKEN1,
            false,
            IRouter(AERO_ROUTER).defaultFactory(),
            amountToken0,
            amountToken1
        );
    }


    // ----------------
    // Internal Methods
    // ----------------

    function _injectLiquidity(
        uint256 amountToken0, 
        uint256 amountToken1,
        uint256 expectedLiquidity,
        uint256 deadline
    ) internal returns (uint256 liquidity) {
        IERC20(TOKEN0).approve(address(AERO_ROUTER), amountToken0);
        IERC20(TOKEN1).approve(address(AERO_ROUTER), amountToken1);
        (,,liquidity) = AERO_ROUTER.addLiquidity(
            TOKEN0, // tokenA
            TOKEN1, // tokenB
            false, // stable
            amountToken0, // amountADesired
            amountToken1, // amountBDesired
            amountToken1-(amountToken1*slippage/1000), // amountAMin
            amountToken0-(amountToken0*slippage/1000), // amountBMin
            address(this), // to
            deadline // deadline
        );
        if (liquidity != expectedLiquidity) {
            revert InsufficientLiquidityReceived(liquidity, expectedLiquidity);
        }
        emit LiquidityInjected(amountToken0, amountToken1, liquidity);
    }

    function _stakeLPTokens(uint256 amount) internal {
        IERC20(POOL).approve(address(GAUGE), amount);
        GAUGE.deposit(amount);
    }

    event Debug(string key, uint256 val);

    function _sellEmissions(uint256 amount) internal returns (uint256 amountEth, uint256 amountUnderlying) {
        // TODO: Get ratio
        (uint256 amount0, uint256 amount1) = AERO_ROUTER.getReserves(TOKEN0, TOKEN1, false, AERO_ROUTER.defaultFactory());
        emit Debug("pool ratio", amount0/amount1*1e12);
        // TODO: Sell for TOKEN0
        uint256 amountForEth = (amount * amount0 / amount1 * 1e12) / 1e22; // TODO Check math
        emit Debug("amount AERO for TOKEN0", amountForEth);
        uint256 ethReceived = _swapForEth(amountForEth);
        // TODO: Sell for USDC
        uint256 amountForUnderlying = amount - amountForEth;
        emit Debug("amount AERO for USDC", amountForUnderlying);
        emit Debug("check ratio", amountForEth/amountForUnderlying*1e12);
    }

    function _swapForEth(uint256 amount) internal returns (uint256 amountReceived) { // TODO: Refactor
        IRouter.Route[] memory route = new IRouter.Route[](1);
        route[0] = IRouter.Route({
            from: address(AERO),
            to: WETH,
            stable: false,
            factory: AERO_ROUTER.defaultFactory()
        });
        AERO.approve(address(AERO_ROUTER), amount);
        AERO_ROUTER.swapExactTokensForETH(amount, 0, route, address(this), block.timestamp); // TODO Get quote
    }

    function _claimEmissions() internal returns (uint256) {}

    /**
     * @notice Overriden from UUPSUpgradeable
     * @dev Restricts ability to upgrade contract to owner
     */
    function _authorizeUpgrade(address) internal override onlyOwner {}

}