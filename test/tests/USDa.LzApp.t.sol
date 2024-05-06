// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {USDa} from "../../src/USDa.sol";
import {BaseSetup} from "../BaseSetup.sol";
import {LZEndpointMock} from "../mock/LZEndpointMock.sol";

contract USDaLzAppTest is Test, BaseSetup {
    USDa internal _usdaToken;

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

        _usdaToken = new USDa(block.chainid, address(_lzEndpoint));
        ERC1967Proxy _usdaTokenProxy = new ERC1967Proxy(
            address(_usdaToken), abi.encodeWithSelector(USDa.initialize.selector, _owner, _rebaseManager)
        );
        _usdaToken = USDa(address(_usdaTokenProxy));
        vm.label(address(_usdaToken), "USDa_Proxy");

        vm.prank(_owner);
        _usdaToken.setMinter(_minter);
    }

    function test_lzApp_CorrectInitialConfig() public {
        assertEq(_usdaToken.owner(), _owner);
        assertEq(_usdaToken.minter(), _minter);
        assertEq(_usdaToken.rebaseManager(), _rebaseManager);
        assertEq(address(_usdaToken.lzEndpoint()), address(_lzEndpoint));
        assertEq(_usdaToken.isMainChain(), true);
    }

    function test_lzApp_setConfig_onlyOwner() public {
        bytes memory newConfig = abi.encodePacked(uint16(1));

        vm.prank(_bob);
        vm.expectRevert();
        _usdaToken.setConfig(uint16(1), uint16(block.chainid), 1, newConfig);

        vm.prank(_owner);
        _usdaToken.setConfig(uint16(1), uint16(block.chainid), 1, newConfig);
    }

    function test_lzApp_setSendVersion_onlyOwner() public {
        vm.prank(_bob);
        vm.expectRevert();
        _usdaToken.setSendVersion(uint16(2));

        vm.prank(_owner);
        _usdaToken.setSendVersion(uint16(2));
    }

    function test_lzApp_setReceiveVersion_onlyOwner() public {
        vm.prank(_bob);
        vm.expectRevert();
        _usdaToken.setReceiveVersion(uint16(2));

        vm.prank(_owner);
        _usdaToken.setReceiveVersion(uint16(2));
    }

    function test_lzApp_setTrustedRemoteAddress() public {
        bytes memory remote = abi.encodePacked(address(2), address(_usdaToken));
        uint16 remoteChainId = 1;

        assertEq(_usdaToken.trustedRemoteLookup(remoteChainId), "");

        vm.prank(_owner);
        _usdaToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));

        assertEq(_usdaToken.trustedRemoteLookup(remoteChainId), remote);
    }

    function test_lzApp_setTrustedRemoteAddress_onlyOwner() public {
        uint16 remoteChainId = 1;

        vm.prank(_bob);
        vm.expectRevert();
        _usdaToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));

        vm.prank(_owner);
        _usdaToken.setTrustedRemoteAddress(remoteChainId, abi.encodePacked(address(2)));
    }
}
