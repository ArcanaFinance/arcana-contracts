// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPool} from "@aero/contracts/interfaces/IPool.sol";
import {IRouter} from "@aero/contracts/interfaces/IRouter.sol";
import {IGauge} from "@aero/contracts/interfaces/IGauge.sol";

import {AeroLooper} from "../../src/AeroLooper.sol";
import {CommonErrors} from "../../src/interfaces/CommonErrors.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";


contract AeroLooperTest is Test {
    string public BASE_RPC_URL = vm.envString("BASE_RPC_URL");

    AeroLooper aeroLooper;

    IPool internal constant POOL = IPool(0xcDAC0d6c6C59727a65F871236188350531885C43);
    IGauge internal gauge;

    address internal constant owner = address(bytes20(bytes("owner")));
    address internal constant bob = address(bytes20(bytes("bob")));

    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDC_MASTERMINTER = 0x2230393EDAD0299b7E7B59F20AA856cD1bEd52e1;

    struct LiquidityData {
        uint256 amount0Deposited;
        uint256 amount1Deposited;
        uint256 liquidityMinted;
    }
    LiquidityData public liquidityData;

    function setUp() public {
        vm.createSelectFork(BASE_RPC_URL);

        // ~ Deployment ~

        vm.startPrank(owner);
        aeroLooper = new AeroLooper(AERO_ROUTER, address(POOL));
        ERC1967Proxy aeroLooperProxy = new ERC1967Proxy(
            address(aeroLooper),
            abi.encodeWithSelector(AeroLooper.initialize.selector)
        );
        aeroLooper = AeroLooper(payable(address(aeroLooperProxy)));
        vm.stopPrank();

        // ~ testing config ~

        gauge = aeroLooper.GAUGE();

        // configure minter to mint USDC
        vm.prank(BASE_USDC_MASTERMINTER);
        (bool success,) = BASE_USDC.call(abi.encodeWithSignature("configureMinter(address,uint256)", owner, type(uint256).max));
        require(success, "configMinter failed");
    }


    // -------
    // Utility
    // -------

    /// @dev Deals Base USDC
    function _dealUSDC(address to, uint256 amount) internal {
        vm.prank(owner); // masterMinter
        (bool success,) = BASE_USDC.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(success, "mint failed");
    }

    /// @dev Will store `amount` directly to the Gauge's rewards mapping for a given `acount`.
    function _emulateRewards(address account, uint256 amount) internal {
        // deal reward token (AERO) to the Gauge
        deal(AERO, address(gauge), amount);
        // store reward amount 
        uint256 mapSlot = 8;
        bytes32 slot = keccak256(abi.encode(account, mapSlot));
        vm.store(address(gauge), slot, bytes32(amount));
    }

    /// @dev Will return the ratio of reserves in the pool of the pair provided.
    function _getCurrentRatio(address token0, address token1) internal returns (uint256 amount0, uint256 amount1, uint256 ratio) {
        (amount0, amount1) = IRouter(AERO_ROUTER).getReserves(token0, token1, false, IRouter(AERO_ROUTER).defaultFactory());
        uint256 decimals0 = IERC20Metadata(token0).decimals();
        uint256 decimals1 = IERC20Metadata(token1).decimals();

        uint256 diff;
        address lowerToken;
        if (int256(decimals0) - int256(decimals1) != 0) {
            (diff, lowerToken) = decimals0 > decimals1 ? (decimals0 - decimals1, token1) : (decimals1 - decimals0, token0);
        }

        if (diff != 0) {
            if (lowerToken == token0) {
                ratio = (amount0 * 10**diff) * 10**decimals1 / amount1;
            }
            else {
                ratio = amount0 * 10**decimals0 / (amount1 * 10**diff);
            }
        }
        else {
            ratio = amount0 * 10**decimals0 / amount1;
        }

        emit log_named_uint("ratio", ratio);
    }


    // ----------
    // Unit Tests
    // ----------

    /// @dev Initial State test
    function test_aeroLooper_init_state() public {
        assertEq(address(aeroLooper.AERO_ROUTER()), AERO_ROUTER);
        assertEq(aeroLooper.TOKEN0(), BASE_WETH);
        assertEq(aeroLooper.TOKEN1(), BASE_USDC);
    }

    /// @dev Verifies proper state changes when AeroLooper::injectLiquidity is called.
    ///      Before calling injectLiquidity we must first call AeroLooper::quoteAddLiquidity to identify
    ///      the amount of ETH and underlying to inject, given the current ratio of POOL reserves.
    function test_aeroLooper_injectLiquidity_noFuzz() public {
        // ~ Config ~

        deal(address(BASE_WETH), address(aeroLooper), 1 ether);
        _dealUSDC(address(aeroLooper), 2_000 * 1e6);
        (uint256 amount0, uint256 amount1, uint256 liquidityQuoted) = aeroLooper.quoteAddLiquidity(1 ether, 2_000 * 1e6);

        (uint256 preReserve0, uint256 preReserve1,) = IPool(address(POOL)).getReserves();

        uint256 preBalToken0 = IERC20(BASE_WETH).balanceOf(address(aeroLooper));
        uint256 preBalToken1 = IERC20(BASE_USDC).balanceOf(address(aeroLooper));
        uint256 preBalGauge = IERC20(address(POOL)).balanceOf(address(gauge));

        // ~ Execute injectLiquidity ~

        vm.prank(owner);
        (liquidityData.amount0Deposited, liquidityData.amount1Deposited, liquidityData.liquidityMinted)
            = aeroLooper.injectLiquidity(amount0, amount1, block.timestamp);

        // ~ Post-state check ~

        (uint256 postReserve0, uint256 postReserve1,) = IPool(address(POOL)).getReserves();

        assertApproxEqAbs(postReserve0, preReserve0 + amount0, amount0*aeroLooper.slippage()/1000);
        assertEq(postReserve0, preReserve0 + liquidityData.amount0Deposited);

        assertApproxEqAbs(postReserve1, preReserve1 + amount1, amount1*aeroLooper.slippage()/1000);
        assertEq(postReserve1, preReserve1 + liquidityData.amount1Deposited);

        assertApproxEqAbs(IERC20(BASE_WETH).balanceOf(address(aeroLooper)), preBalToken0 - amount0, amount0*aeroLooper.slippage()/1000);
        assertApproxEqAbs(IERC20(BASE_USDC).balanceOf(address(aeroLooper)), preBalToken1 - amount1, amount1*aeroLooper.slippage()/1000);

        assertApproxEqAbs(IERC20(address(POOL)).balanceOf(address(gauge)), preBalGauge + liquidityQuoted, liquidityQuoted*aeroLooper.slippage()/1000);
        assertEq(IERC20(address(POOL)).balanceOf(address(gauge)), preBalGauge + liquidityData.liquidityMinted);
        assertEq(gauge.balanceOf(address(aeroLooper)), liquidityData.liquidityMinted);
    }

    /// @dev Uses fuzzing to verify proper state changes when AeroLooper::injectLiquidity is called.
    ///      Before calling injectLiquidity we must first call AeroLooper::quoteAddLiquidity to identify
    ///      the amount of ETH and underlying to inject, given the current ratio of POOL reserves.
    ///      Slippage has been implemented to allow for a small deviation of expected input vs actual input into liq.
    function test_aeroLooper_injectLiquidity_fuzzing(uint256 amountETH, uint256 amountUSDC) public {
        // ~ Config ~

        amountETH = bound(amountETH, .00001 * 1e18, 10 * 1e18);
        amountUSDC = bound(amountUSDC, 1 * 1e6, 100_000 * 1e6);

        deal(address(BASE_WETH), address(aeroLooper), amountETH);
        _dealUSDC(address(aeroLooper), amountUSDC);

        (uint256 amount0, uint256 amount1, uint256 liquidityQuoted) = aeroLooper.quoteAddLiquidity(amountETH, amountUSDC);
        (uint256 preReserve0, uint256 preReserve1,) = IPool(address(POOL)).getReserves();

        uint256 preBalToken0 = IERC20(BASE_WETH).balanceOf(address(aeroLooper));
        uint256 preBalToken1 = IERC20(BASE_USDC).balanceOf(address(aeroLooper));
        uint256 preBalGauge = IERC20(address(POOL)).balanceOf(address(gauge));

        // ~ Execute injectLiquidity ~

        vm.prank(owner);
        (liquidityData.amount0Deposited, liquidityData.amount1Deposited, liquidityData.liquidityMinted)
            = aeroLooper.injectLiquidity(amount0, amount1, block.timestamp);

        // ~ Post-state check ~

        (uint256 postReserve0, uint256 postReserve1,) = IPool(address(POOL)).getReserves();

        assertApproxEqAbs(postReserve0, preReserve0 + amount0, amount0*aeroLooper.slippage()/1000);
        assertEq(postReserve0, preReserve0 + liquidityData.amount0Deposited);

        assertApproxEqAbs(postReserve1, preReserve1 + amount1, amount1*aeroLooper.slippage()/1000);
        assertEq(postReserve1, preReserve1 + liquidityData.amount1Deposited);

        assertApproxEqAbs(IERC20(BASE_WETH).balanceOf(address(aeroLooper)), preBalToken0 - amount0, amount0*aeroLooper.slippage()/1000);
        assertApproxEqAbs(IERC20(BASE_USDC).balanceOf(address(aeroLooper)), preBalToken1 - amount1, amount1*aeroLooper.slippage()/1000);

        assertApproxEqAbs(IERC20(address(POOL)).balanceOf(address(gauge)), preBalGauge + liquidityQuoted, liquidityQuoted*aeroLooper.slippage()/1000);
        assertEq(IERC20(address(POOL)).balanceOf(address(gauge)), preBalGauge + liquidityData.liquidityMinted);
        assertEq(gauge.balanceOf(address(aeroLooper)), liquidityData.liquidityMinted);
    }

    /// @dev This method verifies proper state changes when AeroLooper::claimAndStakeEmissions is called.
    ///      This method does 3 things: First, it will claim any claimable rewards from the Gauge contract. Then, it
    ///      will sell the rewards for token0 and token1. The amounts rely on the portion that is passed when claimAndStakeEmissions
    ///      is called. Lastly, it will inject the amounts of token0 and token1 into the pool and stake the LP tokens minted.
    function test_aeroLooper_claimAndStakeEmissions() public {
        // ~ Config ~

        uint256 amount = 1_000 ether;
        _emulateRewards(address(aeroLooper), amount);

        // ~ Pre-state check ~

        (uint256 preReserve0, uint256 preReserve1,) = IPool(address(POOL)).getReserves();

        uint256 preDeposit = gauge.balanceOf(address(aeroLooper));

        assertEq(gauge.rewards(address(aeroLooper)), amount);

        // ~ claimAndStakeEmissions ~

        vm.prank(owner);
        aeroLooper.claimAndStakeEmissions(.50 * 1e18);

        // post-state check ~

        (uint256 postReserve0, uint256 postReserve1,) = IPool(address(POOL)).getReserves();
        assertGt(postReserve0, preReserve0);
        assertGt(postReserve1, preReserve1);

        assertGt(gauge.balanceOf(address(aeroLooper)), preDeposit);

        assertEq(gauge.rewards(address(aeroLooper)), 0);

    }

    /// @dev Verifies proper state changes when AeroLooper::setSlippage is executed.
    function test_aeroLooper_setSlippage() public {
        // ~ Pre-state check ~

        assertEq(aeroLooper.slippage(), 10);

        // ~ setSlippage ~

        vm.prank(owner);
        aeroLooper.setSlippage(20);

        // ~ Post-state check ~

        assertEq(aeroLooper.slippage(), 20);
    }

    /// @dev Verifies restrictions when AeroLooper::setSlippage is called with unacceptable conditions.
    function test_aeroLooper_setSlippage_restrictions() public {
        // caller must be owner
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AeroLooper.Unauthorized.selector, bob));
        aeroLooper.setSlippage(20);

        // new slippage mustn't be over 1000
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, 1001, 1000));
        aeroLooper.setSlippage(1001);
    }

    /// @dev Verifies proper state changes when AeroLooper::withdrawFromGauge is executed.
    function test_aeroLooper_withdrawFromGauge() public {
        // ~ Config ~

        deal(address(BASE_WETH), address(aeroLooper), 1 ether);
        _dealUSDC(address(aeroLooper), 2_000 * 1e6);

        (uint256 amount0, uint256 amount1,) = aeroLooper.quoteAddLiquidity(1 ether, 2_000 * 1e6);
        uint256 preBalGauge = IERC20(address(POOL)).balanceOf(address(gauge));

        vm.prank(owner);
        (,,uint256 liquidity) = aeroLooper.injectLiquidity(amount0, amount1, block.timestamp);

        // ~ Pre-state check ~

        assertEq(IERC20(address(POOL)).balanceOf(address(gauge)), preBalGauge + liquidity);
        assertEq(gauge.balanceOf(address(aeroLooper)), liquidity);
        assertEq(IERC20(address(POOL)).balanceOf(owner), 0);

        // ~ Execute withdrawFromGauge ~

        vm.prank(owner);
        aeroLooper.withdrawFromGauge(liquidity);

        // ~ Post-state check ~

        assertEq(IERC20(address(POOL)).balanceOf(address(gauge)), preBalGauge);
        assertEq(gauge.balanceOf(address(aeroLooper)), 0);
        assertEq(IERC20(address(POOL)).balanceOf(owner), liquidity);
    }

    /// @dev Verifies restrictions when AeroLooper::withdrawFromGauge is called with unacceptable conditions.
    function test_aeroLooper_withdrawFromGauge_restrictions() public {
        // ~ Config ~

        deal(address(BASE_WETH), address(aeroLooper), 1 ether);
        _dealUSDC(address(aeroLooper), 2_000 * 1e6);
        (uint256 amount0, uint256 amount1,) = aeroLooper.quoteAddLiquidity(1 ether, 2_000 * 1e6);
        vm.prank(owner);
        (,,uint256 liquidity) = aeroLooper.injectLiquidity(amount0, amount1, block.timestamp);

        // ~ Restrictions ~

        // only owner can withdraw
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AeroLooper.Unauthorized.selector, bob));
        aeroLooper.withdrawFromGauge(liquidity);

        // cannot withdraw more than what's deposited
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AeroLooper.AmountExceedsWithdrawable.selector, liquidity));
        aeroLooper.withdrawFromGauge(liquidity+1);
    }

    /// @dev Verifies proper state changes when AeroLooper::withdrawETH is executed.
    function test_aeroLooper_withdrawETH() public {
        // ~ Config ~

        uint256 amount = 1 ether;
        deal(address(aeroLooper), amount);

        // ~ Pre-state check ~

        assertEq(address(aeroLooper).balance, amount);
        assertEq(owner.balance, 0);

        // ~ withdrawETH ~

        vm.prank(owner);
        aeroLooper.withdrawETH(amount);

        // ~ Post-state check ~

        assertEq(address(aeroLooper).balance, 0);
        assertEq(owner.balance, amount);
    }

    /// @dev Verifies restrictions when AeroLooper::withdrawETH is called with unacceptable conditions.
    function test_aeroLooper_withdrawETH_restrictions() public {
        uint256 amount = 1 ether;
        deal(address(aeroLooper), amount);

        // only owner can call withdrawETH
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        aeroLooper.withdrawETH(amount);

        // cannot withraw more than balance
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, amount+1, amount));
        aeroLooper.withdrawETH(amount+1);
    }

    /// @dev Verifies proper state changes when AeroLooper::withdrawERC20 is executed.
    function test_aeroLooper_withdrawERC20() public {
        // ~ Config ~

        uint256 amount = 1 ether;
        _dealUSDC(address(aeroLooper), amount);

        // ~ Pre-state check ~

        assertEq(IERC20(BASE_USDC).balanceOf(address(aeroLooper)), amount);
        assertEq(IERC20(BASE_USDC).balanceOf(owner), 0);

        // ~ withdrawERC20 ~

        vm.prank(owner);
        aeroLooper.withdrawERC20(BASE_USDC, amount);

        // ~ Post-state check ~

        assertEq(IERC20(BASE_USDC).balanceOf(address(aeroLooper)), 0);
        assertEq(IERC20(BASE_USDC).balanceOf(owner), amount);
    }

    /// @dev Verifies restrictions when AeroLooper::withdrawERC20 is called with unacceptable conditions.
    function test_aeroLooper_withdrawERC20_restrictions() public {
        uint256 amount = 1 ether;
        _dealUSDC(address(aeroLooper), amount);

        // only owner can call withdrawERC20
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        aeroLooper.withdrawERC20(BASE_USDC, amount);

        // cannot withraw more than balance
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, amount+1, amount));
        aeroLooper.withdrawERC20(BASE_USDC, amount+1);

        // token cannot be address(0)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        aeroLooper.withdrawERC20(address(0), amount);
    }

    /// @dev Verifies proper state changes when AeroLooper::setAdmin is executed.
    function test_aeroLooper_setAdmin() public {
        // ~ Pre-state check ~

        assertEq(aeroLooper.admin(), address(0));

        // ~ setAdmin ~

        vm.prank(owner);
        aeroLooper.setAdmin(bob);

        // ~ Pre-state check ~

        assertEq(aeroLooper.admin(), bob);
    }

    /// @dev Verifies proper state changes when AeroLooper::setAdmin is called with unacceptable conditions.
    function test_aeroLooper_setAdmin_restrictions() public {
        // only owner can call setAdmin
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        aeroLooper.setAdmin(bob);

        // cannot input address(0)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        aeroLooper.setAdmin(address(0));
    }
}