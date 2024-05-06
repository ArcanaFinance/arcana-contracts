// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {USDa} from "../../src/USDa.sol";
import {IUSDaDefinitions} from "../../src/interfaces/IUSDaDefinitions.sol";
import {USDaTaxManager} from "../../src/USDaTaxManager.sol";
import {BaseSetup} from "../BaseSetup.sol";
import {LZEndpointMock} from "../mock/LZEndpointMock.sol";

contract USDaRebaseTest is Test, BaseSetup {
    USDa internal _usdaToken;
    USDaTaxManager internal _taxCollector;

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

        _usdaToken = new USDa(31337, address(_lzEndpoint));
        ERC1967Proxy _usdaTokenProxy = new ERC1967Proxy(
            address(_usdaToken), abi.encodeWithSelector(USDa.initialize.selector, _owner, _rebaseManager)
        );
        _usdaToken = USDa(address(_usdaTokenProxy));

        _taxCollector = new USDaTaxManager(_owner, address(_usdaToken), _feeCollector);

        vm.prank(_owner);
        _usdaToken.setMinter(_minter);

        vm.prank(_owner);
        _usdaToken.setSupplyLimit(type(uint256).max);

        vm.prank(_owner);
        _usdaToken.setSupplyLimit(type(uint256).max);

        vm.prank(_owner);
        _usdaToken.setTaxManager(address(_taxCollector));
    }

    function test_rebase_CorrectInitialConfig() public {
        assertEq(_usdaToken.owner(), _owner);
        assertEq(_usdaToken.minter(), _minter);
        assertEq(_usdaToken.rebaseManager(), _rebaseManager);
        assertEq(address(_usdaToken.lzEndpoint()), address(_lzEndpoint));
        assertEq(_usdaToken.isMainChain(), true);
    }

    function test_rebase_setRebaseIndex_single() public {
        vm.prank(_minter);
        _usdaToken.mint(_bob, 1 ether);

        assertEq(_usdaToken.rebaseIndex(), 1 ether);
        assertEq(_usdaToken.balanceOf(_feeCollector), 0);

        vm.startPrank(_rebaseManager);
        _usdaToken.setRebaseIndex(2 ether, 1);
        assertGt(_usdaToken.rebaseIndex(), 1 ether);
        assertGt(_usdaToken.balanceOf(_feeCollector), 0);
    }

    function test_rebase_setRebaseIndex_restrictions() public {
        // rebaseIndex can't be 0
        vm.startPrank(_rebaseManager);
        vm.expectRevert(abi.encodeWithSelector(IUSDaDefinitions.ZeroRebaseIndex.selector));
        _usdaToken.setRebaseIndex(0, 1);
    }

    function test_rebase_setRebaseIndex_consecutive() public {
        vm.prank(_minter);
        _usdaToken.mint(_bob, 1000 ether);

        uint256 index1 = 1.2 ether;
        uint256 index2 = 1.4 ether;

        // ~ rebase 1 ~

        assertEq(_usdaToken.rebaseIndex(), 1 ether);
        uint256 feeCollectorPreBal = _usdaToken.balanceOf(_feeCollector);

        uint256 preTotalSupply = _usdaToken.totalSupply();
        uint256 foreshadowTS1 = (((preTotalSupply * 1e18) / _usdaToken.rebaseIndex()) * index1) / 1e18;

        vm.startPrank(_rebaseManager);
        _usdaToken.setRebaseIndex(index1, 1);
        assertGt(_usdaToken.rebaseIndex(), 1 ether); // 1.18

        assertApproxEqAbs(_usdaToken.totalSupply(), foreshadowTS1, 1000);
        assertGt(_usdaToken.balanceOf(_feeCollector), feeCollectorPreBal);

        // ~ rebase 2 ~

        feeCollectorPreBal = _usdaToken.balanceOf(_feeCollector);
        uint256 preIndex = _usdaToken.rebaseIndex();

        preTotalSupply = _usdaToken.totalSupply();
        uint256 foreshadowTS2 = (((preTotalSupply * 1e18) / _usdaToken.rebaseIndex()) * index2) / 1e18;

        vm.startPrank(_rebaseManager);
        _usdaToken.setRebaseIndex(index2, 1);
        assertGt(_usdaToken.rebaseIndex(), preIndex); // 1.378

        assertApproxEqAbs(_usdaToken.totalSupply(), foreshadowTS2, 1000);
        assertGt(_usdaToken.balanceOf(_feeCollector), feeCollectorPreBal);
    }

    function test_rebase_disableRebase() public {
        // ~ Config ~

        uint256 amount = 1 ether;

        vm.startPrank(_minter);
        _usdaToken.mint(_bob, amount);
        _usdaToken.mint(_alice, amount);
        vm.stopPrank();

        // ~ Pre-state check ~

        assertEq(_usdaToken.balanceOf(_bob), amount);
        assertEq(_usdaToken.balanceOf(_alice), amount);

        // ~ Disable rebase for bob  & set rebase ~

        vm.startPrank(_rebaseManager);
        _usdaToken.disableRebase(_bob, true);
        _usdaToken.setRebaseIndex(1.1 ether, 1);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(_usdaToken.balanceOf(_bob), amount);
        assertGt(_usdaToken.balanceOf(_alice), amount);
    }
}
