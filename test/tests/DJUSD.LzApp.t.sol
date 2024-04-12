// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {DJUSD} from "../../src/DJUSD.sol";
import {BaseSetup} from "../BaseSetup.sol";
import {LZEndpointMock} from "../mock/LZEndpointMock.sol";

contract DJUSDLzAppTest is Test, BaseSetup {
    DJUSD internal _djUsdToken;

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

        _lzEndpoint = new LZEndpointMock(uint16(block.chainid));

        _djUsdToken = new DJUSD(block.chainid, address(_lzEndpoint));
        ERC1967Proxy _djUsdTokenProxy = new ERC1967Proxy(
            address(_djUsdToken), abi.encodeWithSelector(DJUSD.initialize.selector, _owner, _rebaseManager)
        );
        _djUsdToken = DJUSD(address(_djUsdTokenProxy));
        vm.label(address(_djUsdToken), "DJUSD_Proxy");

        vm.prank(_owner);
        _djUsdToken.setMinter(_minter);
    }

    function test_lzApp_CorrectInitialConfig() public {
        assertEq(_djUsdToken.owner(), _owner);
        assertEq(_djUsdToken.minter(), _minter);
        assertEq(_djUsdToken.rebaseManager(), _rebaseManager);
        assertEq(address(_djUsdToken.lzEndpoint()), address(_lzEndpoint));
        assertEq(_djUsdToken.isMainChain(), true);
    }

    function test_lzApp_setConfig_onlyOwner() public {
        bytes memory newConfig = abi.encodePacked(uint16(1));

        vm.prank(_bob);
        vm.expectRevert();
        _djUsdToken.setConfig(uint16(1), uint16(block.chainid), 1, newConfig);

        vm.prank(_owner);
        _djUsdToken.setConfig(uint16(1), uint16(block.chainid), 1, newConfig);
    }

    function test_lzApp_setSendVersion_onlyOwner() public {
        vm.prank(_bob);
        vm.expectRevert();
        _djUsdToken.setSendVersion(uint16(2));

        vm.prank(_owner);
        _djUsdToken.setSendVersion(uint16(2));
    }

    function test_lzApp_setReceiveVersion_onlyOwner() public {
        vm.prank(_bob);
        vm.expectRevert();
        _djUsdToken.setReceiveVersion(uint16(2));

        vm.prank(_owner);
        _djUsdToken.setReceiveVersion(uint16(2));
    }

    function test_lzApp_setTrustedRemoteAddress() public {
        bytes memory remote = abi.encodePacked(address(2), address(_djUsdToken));
        uint16 remoteChainId = 1;

        assertEq(_djUsdToken.trustedRemoteLookup(remoteChainId), "");

        vm.prank(_owner);
        _djUsdToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));

        assertEq(_djUsdToken.trustedRemoteLookup(remoteChainId), remote);
    }

    function test_lzApp_setTrustedRemoteAddress_onlyOwner() public {
        uint16 remoteChainId = 1;

        vm.prank(_bob);
        vm.expectRevert();
        _djUsdToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));

        vm.prank(_owner);
        _djUsdToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));
    }
}
