// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import { DJUSD } from "../../src/DJUSD.sol";
import { DJUSDTaxManager } from "../../src/DJUSDTaxManager.sol";
import { BaseSetup } from "../BaseSetup.sol";

contract DJUSDTest is Test, BaseSetup {
    DJUSD internal _djUsdToken;
    DJUSDTaxManager internal _taxManager;

    //address internal constant owner = address(bytes20(bytes("owner")));
    address internal constant _newOwner = address(bytes20(bytes("new owner")));
    address internal constant _minter = address(bytes20(bytes("minter")));
    address internal constant _newMinter = address(bytes20(bytes("new minter")));
    address internal constant _rebaseManager = address(bytes20(bytes("rebaseManager")));
    address internal constant _newRebaseManager = address(bytes20(bytes("new rebaseManager")));
    address internal constant _bob = address(bytes20(bytes("bob")));
    address internal constant _alice = address(bytes20(bytes("alice")));
    address internal constant _feeCollector = address(bytes20(bytes("feeCollector")));
    address internal constant _layerZeroEndpoint = address(bytes20(bytes("lz endpoint")));

    function setUp() public virtual override {
        super.setUp();

        vm.label(_minter, "minter");
        vm.label(owner, "owner");
        vm.label(_newMinter, "_newMinter");
        vm.label(_newOwner, "newOwner");
        vm.label(_rebaseManager, "rebaseManager");
        vm.label(_newRebaseManager, "newRebaseManager");
        vm.label(_layerZeroEndpoint, "layerZeroEndpoint");

        _djUsdToken = new DJUSD(31337, _layerZeroEndpoint);
        ERC1967Proxy _djUsdTokenProxy = new ERC1967Proxy(
            address(_djUsdToken),
            abi.encodeWithSelector(DJUSD.initialize.selector,
                owner,
                _rebaseManager
            )
        );
        _djUsdToken = DJUSD(address(_djUsdTokenProxy));

        _taxManager = new DJUSDTaxManager(address(_djUsdToken), _feeCollector);

        vm.prank(owner);
        _djUsdToken.setMinter(_minter);

        vm.prank(owner);
        _djUsdToken.setSupplyLimit(type(uint256).max);

        vm.prank(owner);
        _djUsdToken.setTaxManager(address(_taxManager));

        
    }

    function test_CorrectInitialConfig() public {
        assertEq(_djUsdToken.owner(), owner);
        assertEq(_djUsdToken.minter(), _minter);
        assertEq(_djUsdToken.rebaseManager(), _rebaseManager);
        assertEq(address(_djUsdToken.lzEndpoint()), _layerZeroEndpoint);
        assertEq(_djUsdToken.isMainChain(), true);
    }

    function test_initialize() public {
        uint256 mainChainId = block.chainid;
        uint256 sideChainId = mainChainId + 1;

        DJUSD instance1 = new DJUSD(mainChainId, address(1));

        vm.chainId(sideChainId);

        DJUSD instance2 = new DJUSD(mainChainId, address(1));

        bytes32 slot = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1))
            & ~bytes32(uint256(0xff));
        vm.store(address(instance1), slot, 0);
        vm.store(address(instance2), slot, 0);

        instance1.initialize(address(2), address(3));
        assertEq(_djUsdToken.name(), "DJUSD");
        assertEq(_djUsdToken.symbol(), "DJUSD");
        assertEq(_djUsdToken.rebaseIndex(), 1 ether);

        instance2.initialize(address(2), address(3));
        assertEq(_djUsdToken.name(), "DJUSD");
        assertEq(_djUsdToken.symbol(), "DJUSD");
        assertEq(_djUsdToken.rebaseIndex(), 1 ether);
    }

    function test_djUsdToken_isUpgradeable() public {
        DJUSD newImplementation = new DJUSD(block.chainid, address(1));

        bytes32 implementationSlot = vm.load(address(_djUsdToken), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        _djUsdToken.upgradeToAndCall(address(newImplementation), "");

        implementationSlot = vm.load(address(_djUsdToken), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_djUsdToken_isUpgradeable_onlyOwner() public {
        DJUSD newImplementation = new DJUSD(block.chainid, address(1));

        vm.prank(_minter);
        vm.expectRevert();
        _djUsdToken.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        _djUsdToken.upgradeToAndCall(address(newImplementation), "");
    }

    function testownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(CantRenounceOwnershipErr);
        _djUsdToken.renounceOwnership();
        assertEq(_djUsdToken.owner(), owner);
        assertNotEq(_djUsdToken.owner(), address(0));
    }

    function test_CanTransferOwnership() public {
        vm.prank(owner);
        _djUsdToken.transferOwnership(_newOwner);
        assertEq(_djUsdToken.owner(), _newOwner);
    }

    function test_NewOwnerCanPerformOwnerActions() public {
        vm.prank(owner);
        _djUsdToken.transferOwnership(_newOwner);
        vm.startPrank(_newOwner);
        _djUsdToken.setMinter(_newMinter);
        vm.stopPrank();
        assertEq(_djUsdToken.minter(), _newMinter);
        assertNotEq(_djUsdToken.minter(), _minter);
    }

    function test_OnlyOwnerCanSetMinter() public {
        vm.prank(_newOwner);
        vm.expectRevert();
        _djUsdToken.setMinter(_newMinter);
        assertEq(_djUsdToken.minter(), _minter);
    }

    function test_OnlyOwnerCanSetRebaseManager() public {
        vm.prank(_newOwner);
        vm.expectRevert();
        _djUsdToken.setRebaseManager(_newRebaseManager);
        assertEq(_djUsdToken.rebaseManager(), _rebaseManager);
        vm.prank(owner);
        _djUsdToken.setRebaseManager(_newRebaseManager);
        assertEq(_djUsdToken.rebaseManager(), _newRebaseManager);
    }

    function testownerCantMint() public {
        vm.prank(owner);
        vm.expectRevert(OnlyMinterErr);
        _djUsdToken.mint(_newMinter, 100);
    }

    function test_MinterCanMint() public {
        assertEq(_djUsdToken.balanceOf(_newMinter), 0);
        vm.prank(_minter);
        _djUsdToken.mint(_newMinter, 100);
        assertEq(_djUsdToken.balanceOf(_newMinter), 100);
    }

    function test_MinterCantMintToZeroAddress() public {
        vm.prank(_minter);
        vm.expectRevert();
        _djUsdToken.mint(address(0), 100);
    }

    function test_NewMinterCanMint() public {
        assertEq(_djUsdToken.balanceOf(_newMinter), 0);
        vm.prank(owner);
        _djUsdToken.setMinter(_newMinter);
        vm.prank(_newMinter);
        _djUsdToken.mint(_newMinter, 100);
        assertEq(_djUsdToken.balanceOf(_newMinter), 100);
    }

    function test_OldMinterCantMint() public {
        assertEq(_djUsdToken.balanceOf(_newMinter), 0);
        vm.prank(owner);
        _djUsdToken.setMinter(_newMinter);
        vm.prank(_minter);
        vm.expectRevert(OnlyMinterErr);
        _djUsdToken.mint(_newMinter, 100);
        assertEq(_djUsdToken.balanceOf(_newMinter), 0);
    }

    function test_OldOwnerCantTransferOwnership() public {
        vm.prank(owner);
        _djUsdToken.transferOwnership(_newOwner);
        vm.prank(_newOwner);
        assertNotEq(_djUsdToken.owner(), owner);
        assertEq(_djUsdToken.owner(), _newOwner);
        vm.prank(owner);
        vm.expectRevert();
        _djUsdToken.transferOwnership(_newMinter);
        assertEq(_djUsdToken.owner(), _newOwner);
    }

    function test_OldOwnerCantSetMinter() public {
        vm.prank(owner);
        _djUsdToken.transferOwnership(_newOwner);
        assertEq(_djUsdToken.owner(), _newOwner);
        vm.expectRevert();
        _djUsdToken.setMinter(_newMinter);
        assertEq(_djUsdToken.minter(), _minter);
    }
}
