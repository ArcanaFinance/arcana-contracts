// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    IPool internal pool;
    IGauge internal gauge;

    address internal constant owner = address(bytes20(bytes("owner")));
    address internal constant bob = address(bytes20(bytes("bob")));

    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDC_MASTERMINTER = 0x2230393EDAD0299b7E7B59F20AA856cD1bEd52e1;

    function setUp() public {
        vm.createSelectFork(BASE_RPC_URL);

        // ~ Deployment ~

        vm.startPrank(owner);
        aeroLooper = new AeroLooper(AERO_ROUTER, BASE_USDC);
        ERC1967Proxy aeroLooperProxy = new ERC1967Proxy(
            address(aeroLooper),
            abi.encodeWithSelector(AeroLooper.initialize.selector)
        );
        aeroLooper = AeroLooper(payable(address(aeroLooperProxy)));
        vm.stopPrank();

        // ~ testing config ~

        gauge = aeroLooper.GAUGE();
        pool = IPool(aeroLooper.POOL());

        // configure minter to mint USDC
        vm.prank(BASE_USDC_MASTERMINTER);
        (bool success,) = BASE_USDC.call(abi.encodeWithSignature("configureMinter(address,uint256)", owner, type(uint256).max));
        require(success, "configMinter failed");
    }


    // -------
    // Utility
    // -------

    function _dealUnderlying(address to, uint256 amount) internal {
        vm.prank(owner); // masterMinter
        (bool success,) = BASE_USDC.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(success, "mint failed");
    }

    function _emulateRewards(address account, uint256 amount) internal {
        // deal reward token (AERO) to the Gauge
        deal(AERO, address(gauge), amount);
        // store reward amount 
        uint256 mapSlot = 8;
        bytes32 slot = keccak256(abi.encode(account, mapSlot));
        vm.store(address(gauge), slot, bytes32(amount));
    }


    // ----------
    // Unit Tests
    // ----------

    /// @dev Initial State test
    function test_aeroLooper_init_state() public {
        assertEq(address(aeroLooper.AERO_ROUTER()), AERO_ROUTER);
        assertEq(aeroLooper.UNDERLYING(), BASE_USDC);
    }

    /// @dev Verifies proper state changes when AeroLooper::injectLiquidity is called.
    ///      Before calling injectLiquidity we must first call AeroLooper::quoteAddLiquidity to identify
    ///      the amount of ETH and underlying to inject, given the current ratio of pool reserves.
    function test_aeroLooper_injectLiquidity() public {
        // ~ Config ~

        vm.deal(address(aeroLooper), 1 ether);
        _dealUnderlying(address(aeroLooper), 2_000 * 1e6);
        (uint256 amount0, uint256 amount1, uint256 liquidity) = aeroLooper.quoteAddLiquidity(1 ether, 2_000 * 1e6);

        (uint256 preReserve0, uint256 preReserve1,) = IPool(address(pool)).getReserves();

        uint256 preBalEth = address(aeroLooper).balance;
        uint256 preBalTkn = IERC20(BASE_USDC).balanceOf(address(aeroLooper));
        uint256 preBalGauge = IERC20(address(pool)).balanceOf(address(gauge));

        // ~ Execute injectLiquidity ~

        vm.prank(owner);
        aeroLooper.injectLiquidity(amount0, amount1, liquidity, block.timestamp);

        // ~ Post-state check ~

        (uint256 postReserve0, uint256 postReserve1,) = IPool(address(pool)).getReserves();

        assertEq(postReserve0, preReserve0 + amount0);
        assertEq(postReserve1, preReserve1 + amount1);

        assertEq(address(aeroLooper).balance, preBalEth - amount0);
        assertEq(IERC20(BASE_USDC).balanceOf(address(aeroLooper)), preBalTkn - amount1);

        assertEq(IERC20(address(pool)).balanceOf(address(gauge)), preBalGauge + liquidity);
        assertEq(gauge.balanceOf(address(aeroLooper)), liquidity);
    }

    /// @dev Uses fuzzing to verify proper state changes when AeroLooper::injectLiquidity is called.
    ///      Before calling injectLiquidity we must first call AeroLooper::quoteAddLiquidity to identify
    ///      the amount of ETH and underlying to inject, given the current ratio of pool reserves.
    ///      Slippage has been implemented to allow for a small deviation of expected input vs actual input into liq.
    function test_aeroLooper_injectLiquidity_fuzzing(uint256 amountETH, uint256 amountUSDC) public {
        // ~ Config ~

        amountETH = bound(amountETH, .00001 * 1e18, 10 * 1e18);
        amountUSDC = bound(amountUSDC, 1 * 1e6, 100_000 * 1e6);

        vm.deal(address(aeroLooper), amountETH);
        _dealUnderlying(address(aeroLooper), amountUSDC);

        (uint256 amount0, uint256 amount1, uint256 liquidity) = aeroLooper.quoteAddLiquidity(amountETH, amountUSDC);
        (uint256 preReserve0, uint256 preReserve1,) = IPool(address(pool)).getReserves();

        uint256 preBalEth = address(aeroLooper).balance;
        uint256 preBalTkn = IERC20(BASE_USDC).balanceOf(address(aeroLooper));
        uint256 preBalGauge = IERC20(address(pool)).balanceOf(address(gauge));

        // ~ Execute injectLiquidity ~

        vm.prank(owner);
        aeroLooper.injectLiquidity(amount0, amount1, liquidity, block.timestamp);

        // ~ Post-state check ~

        (uint256 postReserve0, uint256 postReserve1,) = IPool(address(pool)).getReserves();

        assertApproxEqAbs(postReserve0, preReserve0 + amount0, amount0*aeroLooper.slippage()/1000);
        assertApproxEqAbs(postReserve1, preReserve1 + amount1, amount1*aeroLooper.slippage()/1000);

        assertApproxEqAbs(address(aeroLooper).balance, preBalEth - amount0, amount0*aeroLooper.slippage()/1000);
        assertApproxEqAbs(IERC20(BASE_USDC).balanceOf(address(aeroLooper)), preBalTkn - amount1, amount1*aeroLooper.slippage()/1000);

        assertEq(IERC20(address(pool)).balanceOf(address(gauge)), preBalGauge + liquidity);
        assertEq(gauge.balanceOf(address(aeroLooper)), liquidity);
    }

    function test_aeroLooper_claimAndStakeEmissions() public {
        // ~ Config ~

        uint256 amount = 1 ether;
        _emulateRewards(address(aeroLooper), amount);

        // ~ Pre-state check ~

        assertEq(gauge.rewards(address(aeroLooper)), amount);

        // ~ claimAndStakeEmissions ~

        vm.prank(owner);
        aeroLooper.claimAndStakeEmissions();

        // post state
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        aeroLooper.setSlippage(20);

        // new slippage mustn't be over 1000
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, 1001, 1000));
        aeroLooper.setSlippage(1001);
    }

    /// @dev Verifies proper state changes when AeroLooper::withdrawFromGauge is executed.
    function test_aeroLooper_withdrawFromGauge() public {
        // ~ Config ~

        vm.deal(address(aeroLooper), 1 ether);
        _dealUnderlying(address(aeroLooper), 2_000 * 1e6);

        (uint256 amount0, uint256 amount1, uint256 liquidity) = aeroLooper.quoteAddLiquidity(1 ether, 2_000 * 1e6);
        uint256 preBalGauge = IERC20(address(pool)).balanceOf(address(gauge));

        vm.prank(owner);
        aeroLooper.injectLiquidity(amount0, amount1, liquidity, block.timestamp);

        // ~ Pre-state check ~

        assertEq(IERC20(address(pool)).balanceOf(address(gauge)), preBalGauge + liquidity);
        assertEq(gauge.balanceOf(address(aeroLooper)), liquidity);
        assertEq(IERC20(address(pool)).balanceOf(owner), 0);

        // ~ Execute withdrawFromGauge ~

        vm.prank(owner);
        aeroLooper.withdrawFromGauge(liquidity);

        // ~ Post-state check ~

        assertEq(IERC20(address(pool)).balanceOf(address(gauge)), preBalGauge);
        assertEq(gauge.balanceOf(address(aeroLooper)), 0);
        assertEq(IERC20(address(pool)).balanceOf(owner), liquidity);
    }

    /// @dev Verifies restrictions when AeroLooper::withdrawFromGauge is called with unacceptable conditions.
    function test_aeroLooper_withdrawFromGauge_restrictions() public {
        // ~ Config ~

        vm.deal(address(aeroLooper), 1 ether);
        _dealUnderlying(address(aeroLooper), 2_000 * 1e6);
        (uint256 amount0, uint256 amount1, uint256 liquidity) = aeroLooper.quoteAddLiquidity(1 ether, 2_000 * 1e6);
        vm.prank(owner);
        aeroLooper.injectLiquidity(amount0, amount1, liquidity, block.timestamp);

        // ~ Restrictions ~

        // only owner can withdraw
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
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
        _dealUnderlying(address(aeroLooper), amount);

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
        _dealUnderlying(address(aeroLooper), amount);

        // only owner can call withdrawERC20
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        aeroLooper.withdrawERC20(BASE_USDC, amount);

        // cannot withraw more than balance
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, amount+1, amount));
        aeroLooper.withdrawERC20(BASE_USDC, amount+1);
    }
}
