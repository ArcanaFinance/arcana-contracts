// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {arcUSD} from "../../src/arcUSD.sol";
import {BaseSetup} from "../BaseSetup.sol";
import {LZEndpointMock} from "../mock/LZEndpointMock.sol";

contract arcUSDLzAppTest is Test, BaseSetup {
    arcUSD internal _arcUSDToken;

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

        _arcUSDToken = new arcUSD(block.chainid, address(_lzEndpoint));
        ERC1967Proxy _arcUSDTokenProxy = new ERC1967Proxy(
            address(_arcUSDToken), abi.encodeWithSelector(arcUSD.initialize.selector, _owner, _rebaseManager)
        );
        _arcUSDToken = arcUSD(address(_arcUSDTokenProxy));
        vm.label(address(_arcUSDToken), "arcUSD_Proxy");

        vm.prank(_owner);
        _arcUSDToken.setMinter(_minter);
    }

    function test_lzApp_CorrectInitialConfig() public {
        assertEq(_arcUSDToken.owner(), _owner);
        assertEq(_arcUSDToken.minter(), _minter);
        assertEq(_arcUSDToken.rebaseManager(), _rebaseManager);
        assertEq(address(_arcUSDToken.lzEndpoint()), address(_lzEndpoint));
        assertEq(_arcUSDToken.isMainChain(), true);
    }

    function test_lzApp_setConfig_onlyOwner() public {
        bytes memory newConfig = abi.encodePacked(uint16(1));

        vm.prank(_bob);
        vm.expectRevert();
        _arcUSDToken.setConfig(uint16(1), uint16(block.chainid), 1, newConfig);

        vm.prank(_owner);
        _arcUSDToken.setConfig(uint16(1), uint16(block.chainid), 1, newConfig);
    }

    function test_lzApp_setSendVersion_onlyOwner() public {
        vm.prank(_bob);
        vm.expectRevert();
        _arcUSDToken.setSendVersion(uint16(2));

        vm.prank(_owner);
        _arcUSDToken.setSendVersion(uint16(2));
    }

    function test_lzApp_setReceiveVersion_onlyOwner() public {
        vm.prank(_bob);
        vm.expectRevert();
        _arcUSDToken.setReceiveVersion(uint16(2));

        vm.prank(_owner);
        _arcUSDToken.setReceiveVersion(uint16(2));
    }

    function test_lzApp_setTrustedRemoteAddress() public {
        bytes memory remote = abi.encodePacked(address(2), address(_arcUSDToken));
        uint16 remoteChainId = 1;

        assertEq(_arcUSDToken.trustedRemoteLookup(remoteChainId), "");

        vm.prank(_owner);
        _arcUSDToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));

        assertEq(_arcUSDToken.trustedRemoteLookup(remoteChainId), remote);
    }

    function test_lzApp_setTrustedRemoteAddress_onlyOwner() public {
        uint16 remoteChainId = 1;

        vm.prank(_bob);
        vm.expectRevert();
        _arcUSDToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));

        vm.prank(_owner);
        _arcUSDToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));
    }
}
