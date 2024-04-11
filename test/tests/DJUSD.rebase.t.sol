// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {DJUSD} from "../../src/DJUSD.sol";
import {DJUSDTaxManager} from "../../src/DJUSDTaxManager.sol";
import {BaseSetup} from "../BaseSetup.sol";
import {LZEndpointMock} from "../mock/LZEndpointMock.sol";

contract DJUSDRebaseTest is Test, BaseSetup {
    DJUSD internal _djUsdToken;
    DJUSDTaxManager internal _taxCollector;

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

        _djUsdToken = new DJUSD(31337, address(_lzEndpoint));
        ERC1967Proxy _djUsdTokenProxy = new ERC1967Proxy(
            address(_djUsdToken),
            abi.encodeWithSelector(DJUSD.initialize.selector,
                _owner,
                _rebaseManager
            )
        );
        _djUsdToken = DJUSD(address(_djUsdTokenProxy));

        _taxCollector = new DJUSDTaxManager(_owner, address(_djUsdToken), _feeCollector);

        vm.prank(_owner);
        _djUsdToken.setMinter(_minter);

        vm.prank(_owner);
        _djUsdToken.setSupplyLimit(type(uint256).max);

        vm.prank(_owner);
        _djUsdToken.setSupplyLimit(type(uint256).max);

        vm.prank(_owner);
        _djUsdToken.setTaxManager(address(_taxCollector));
    }

    function test_rebase_CorrectInitialConfig() public {
        assertEq(_djUsdToken.owner(), _owner);
        assertEq(_djUsdToken.minter(), _minter);
        assertEq(_djUsdToken.rebaseManager(), _rebaseManager);
        assertEq(address(_djUsdToken.lzEndpoint()), address(_lzEndpoint));
        assertEq(_djUsdToken.isMainChain(), true);
    }

    function test_rebase_setRebaseIndex_single() public {
        vm.prank(_minter);
        _djUsdToken.mint(_bob, 1 ether);

        assertEq(_djUsdToken.rebaseIndex(), 1 ether);
        assertEq(_djUsdToken.balanceOf(_feeCollector), 0);

        vm.startPrank(_rebaseManager);
        _djUsdToken.setRebaseIndex(2 ether, 1);
        assertGt(_djUsdToken.rebaseIndex(), 1 ether);
        assertGt(_djUsdToken.balanceOf(_feeCollector), 0);
    }

    function test_rebase_setRebaseIndex_consecutive() public {
        vm.prank(_minter);
        _djUsdToken.mint(_bob, 1000 ether);

        uint256 index1 = 1.2 ether;
        uint256 index2 = 1.4 ether;

        // ~ rebase 1 ~

        assertEq(_djUsdToken.rebaseIndex(), 1 ether);
        uint256 feeCollectorPreBal = _djUsdToken.balanceOf(_feeCollector);

        uint256 preTotalSupply = _djUsdToken.totalSupply();
        uint256 foreshadowTS1 = (((preTotalSupply * 1e18) / _djUsdToken.rebaseIndex()) * index1) / 1e18;

        vm.startPrank(_rebaseManager);
        _djUsdToken.setRebaseIndex(index1, 1);
        assertGt(_djUsdToken.rebaseIndex(), 1 ether); // 1.18

        assertApproxEqAbs(_djUsdToken.totalSupply(), foreshadowTS1, 1000);
        assertGt(_djUsdToken.balanceOf(_feeCollector), feeCollectorPreBal);

        // ~ rebase 2 ~

        feeCollectorPreBal = _djUsdToken.balanceOf(_feeCollector);
        uint256 preIndex = _djUsdToken.rebaseIndex();

        preTotalSupply = _djUsdToken.totalSupply();
        uint256 foreshadowTS2 = (((preTotalSupply * 1e18) / _djUsdToken.rebaseIndex()) * index2) / 1e18;

        vm.startPrank(_rebaseManager);
        _djUsdToken.setRebaseIndex(index2, 1);
        assertGt(_djUsdToken.rebaseIndex(), preIndex); // 1.378

        assertApproxEqAbs(_djUsdToken.totalSupply(), foreshadowTS2, 1000);
        assertGt(_djUsdToken.balanceOf(_feeCollector), feeCollectorPreBal);
    }

    function test_rebase_disableRebase() public {
        // ~ Config ~

        uint256 amount = 1 ether;

        vm.startPrank(_minter);
        _djUsdToken.mint(_bob, amount);
        _djUsdToken.mint(_alice, amount);
        vm.stopPrank();

        // ~ Pre-state check ~

        assertEq(_djUsdToken.balanceOf(_bob), amount);
        assertEq(_djUsdToken.balanceOf(_alice), amount);

        // ~ Disable rebase for bob  & set rebase ~

        vm.startPrank(_rebaseManager);
        _djUsdToken.disableRebase(_bob, true);
        _djUsdToken.setRebaseIndex(1.1 ether, 1);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(_djUsdToken.balanceOf(_bob), amount);
        assertGt(_djUsdToken.balanceOf(_alice), amount);
    }
}
