// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSDDefinitions} from "../../src/interfaces/IarcUSDDefinitions.sol";
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {BaseSetup} from "../BaseSetup.sol";
import {LZEndpointMock} from "../mock/LZEndpointMock.sol";

contract arcUSDRebaseTest is Test, BaseSetup {
    arcUSD internal _arcUSDToken;
    arcUSDTaxManager internal _taxCollector;

    // mock
    LZEndpointMock internal _lzEndpoint;

    address internal constant _owner = address(bytes20(bytes("owner")));
    address internal constant _minter = address(bytes20(bytes("minter")));
    address internal constant _rebaseManager = address(bytes20(bytes("rebaseManager")));
    address internal constant _bob = address(bytes20(bytes("bob")));
    address internal constant _alice = address(bytes20(bytes("alice")));
    address internal constant _feeCollector = address(bytes20(bytes("feeCollector")));

    function setUp() public virtual override {
        vm.label(_minter, "minter");
        vm.label(_owner, "owner");
        vm.label(_rebaseManager, "rebaseManager");
        vm.label(_bob, "bob");
        vm.label(_alice, "alice");
        vm.label(_feeCollector, "feeCollector");

        _lzEndpoint = new LZEndpointMock(uint16(block.chainid));

        _arcUSDToken = new arcUSD(31337, address(_lzEndpoint));
        ERC1967Proxy _arcUSDTokenProxy = new ERC1967Proxy(
            address(_arcUSDToken), abi.encodeWithSelector(arcUSD.initialize.selector, _owner, _rebaseManager)
        );
        _arcUSDToken = arcUSD(address(_arcUSDTokenProxy));

        _taxCollector = new arcUSDTaxManager(_owner, address(_arcUSDToken), _feeCollector);

        vm.prank(_owner);
        _arcUSDToken.setMinter(_minter);

        vm.prank(_owner);
        _arcUSDToken.setSupplyLimit(type(uint256).max);

        vm.prank(_owner);
        _arcUSDToken.setSupplyLimit(type(uint256).max);

        vm.prank(_owner);
        _arcUSDToken.setTaxManager(address(_taxCollector));
    }

    function test_rebase_CorrectInitialConfig() public {
        assertEq(_arcUSDToken.owner(), _owner);
        assertEq(_arcUSDToken.minter(), _minter);
        assertEq(_arcUSDToken.rebaseManager(), _rebaseManager);
        assertEq(address(_arcUSDToken.lzEndpoint()), address(_lzEndpoint));
        assertEq(_arcUSDToken.isMainChain(), true);
    }

    function test_rebase_setRebaseIndex_single() public {
        vm.prank(_minter);
        _arcUSDToken.mint(_bob, 1 ether);

        assertEq(_arcUSDToken.rebaseIndex(), 1 ether);
        assertEq(_arcUSDToken.balanceOf(_feeCollector), 0);

        vm.startPrank(_rebaseManager);
        _arcUSDToken.setRebaseIndex(2 ether, 1);
        assertGt(_arcUSDToken.rebaseIndex(), 1 ether);
        assertGt(_arcUSDToken.balanceOf(_feeCollector), 0);
    }

    function test_rebase_setRebaseIndex_restrictions() public {
        // rebaseIndex can't be 0
        vm.startPrank(_rebaseManager);
        vm.expectRevert(abi.encodeWithSelector(IarcUSDDefinitions.ZeroRebaseIndex.selector));
        _arcUSDToken.setRebaseIndex(0, 1);
    }

    function test_rebase_setRebaseIndex_consecutive() public {
        vm.prank(_minter);
        _arcUSDToken.mint(_bob, 1000 ether);

        uint256 index1 = 1.2 ether;
        uint256 index2 = 1.4 ether;

        // ~ rebase 1 ~

        assertEq(_arcUSDToken.rebaseIndex(), 1 ether);
        uint256 feeCollectorPreBal = _arcUSDToken.balanceOf(_feeCollector);

        uint256 preTotalSupply = _arcUSDToken.totalSupply();
        uint256 foreshadowTS1 = (((preTotalSupply * 1e18) / _arcUSDToken.rebaseIndex()) * index1) / 1e18;

        vm.startPrank(_rebaseManager);
        _arcUSDToken.setRebaseIndex(index1, 1);
        assertGt(_arcUSDToken.rebaseIndex(), 1 ether); // 1.18

        assertApproxEqAbs(_arcUSDToken.totalSupply(), foreshadowTS1, 1000);
        assertGt(_arcUSDToken.balanceOf(_feeCollector), feeCollectorPreBal);

        // ~ rebase 2 ~

        feeCollectorPreBal = _arcUSDToken.balanceOf(_feeCollector);
        uint256 preIndex = _arcUSDToken.rebaseIndex();

        preTotalSupply = _arcUSDToken.totalSupply();
        uint256 foreshadowTS2 = (((preTotalSupply * 1e18) / _arcUSDToken.rebaseIndex()) * index2) / 1e18;

        vm.startPrank(_rebaseManager);
        _arcUSDToken.setRebaseIndex(index2, 1);
        assertGt(_arcUSDToken.rebaseIndex(), preIndex); // 1.378

        assertApproxEqAbs(_arcUSDToken.totalSupply(), foreshadowTS2, 1000);
        assertGt(_arcUSDToken.balanceOf(_feeCollector), feeCollectorPreBal);
    }

    function test_rebase_disableRebase() public {
        // ~ Config ~

        uint256 amount = 1 ether;

        vm.startPrank(_minter);
        _arcUSDToken.mint(_bob, amount);
        _arcUSDToken.mint(_alice, amount);
        vm.stopPrank();

        // ~ Pre-state check ~

        assertEq(_arcUSDToken.optedOutTotalSupply(), 0);
        assertEq(_arcUSDToken.balanceOf(_bob), amount);
        assertEq(_arcUSDToken.balanceOf(_alice), amount);

        // ~ Disable rebase for bob  & set rebase ~

        vm.startPrank(_rebaseManager);
        _arcUSDToken.disableRebase(_bob, true);
        _arcUSDToken.setRebaseIndex(1.1 ether, 1);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(_arcUSDToken.balanceOf(_bob), amount);
        assertGt(_arcUSDToken.balanceOf(_alice), amount);
        assertEq(_arcUSDToken.optedOutTotalSupply(), amount);
    }

    function test_rebase_halfOptedOut() public {
        // ~ Config ~

        uint256 amount = 100 ether;
        uint256 newRebaseIndex = 1.05 ether;

        vm.startPrank(_minter);
        _arcUSDToken.mint(_bob, amount);
        _arcUSDToken.mint(_alice, amount);
        vm.stopPrank();

        uint256 supply = amount * 2;
        uint256 newSupply = (amount * newRebaseIndex / 1e18) + amount; // 2.1
        emit log_uint(newSupply);

        // ~ Pre-state check ~

        assertEq(_arcUSDToken.optedOutTotalSupply(), 0);
        assertEq(_arcUSDToken.balanceOf(_bob), amount);
        assertEq(_arcUSDToken.balanceOf(_alice), amount);
        assertEq(_arcUSDToken.balanceOf(address(_feeCollector)), 0);

        // ~ Disable rebase for bob  & set rebase ~

        vm.startPrank(_rebaseManager);
        _arcUSDToken.disableRebase(_bob, true);
        _arcUSDToken.setRebaseIndex(newRebaseIndex, 1);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(_arcUSDToken.balanceOf(_bob), amount);
        assertGt(_arcUSDToken.balanceOf(_alice), amount);
        assertEq(_arcUSDToken.optedOutTotalSupply(), amount);
        assertApproxEqAbs(_arcUSDToken.balanceOf(address(_feeCollector)), (newSupply - supply)*_taxCollector.taxRate()/1e18, 1);
    }
}
