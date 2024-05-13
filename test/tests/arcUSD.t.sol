// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {arcUSD} from "../../src/arcUSD.sol";
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {BaseSetup} from "../BaseSetup.sol";

contract arcUSDTest is Test, BaseSetup {
    arcUSD internal _arcUSDToken;
    arcUSDTaxManager internal _taxManager;

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

        _arcUSDToken = new arcUSD(31337, _layerZeroEndpoint);
        ERC1967Proxy _arcUSDTokenProxy = new ERC1967Proxy(
            address(_arcUSDToken), abi.encodeWithSelector(arcUSD.initialize.selector, owner, _rebaseManager)
        );
        _arcUSDToken = arcUSD(address(_arcUSDTokenProxy));

        _taxManager = new arcUSDTaxManager(owner, address(_arcUSDToken), _feeCollector);

        vm.prank(owner);
        _arcUSDToken.setMinter(_minter);

        vm.prank(owner);
        _arcUSDToken.setSupplyLimit(type(uint256).max);

        vm.prank(owner);
        _arcUSDToken.setTaxManager(address(_taxManager));
    }

    function test_CorrectInitialConfig() public {
        assertEq(_arcUSDToken.owner(), owner);
        assertEq(_arcUSDToken.minter(), _minter);
        assertEq(_arcUSDToken.rebaseManager(), _rebaseManager);
        assertEq(address(_arcUSDToken.lzEndpoint()), _layerZeroEndpoint);
        assertEq(_arcUSDToken.isMainChain(), true);
    }

    function test_initialize() public {
        uint256 mainChainId = block.chainid;
        uint256 sideChainId = mainChainId + 1;

        arcUSD instance1 = new arcUSD(mainChainId, address(1));

        vm.chainId(sideChainId);

        arcUSD instance2 = new arcUSD(mainChainId, address(1));

        bytes32 slot = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1))
            & ~bytes32(uint256(0xff));
        vm.store(address(instance1), slot, 0);
        vm.store(address(instance2), slot, 0);

        instance1.initialize(address(2), address(3));
        assertEq(_arcUSDToken.name(), "arcUSD");
        assertEq(_arcUSDToken.symbol(), "arcUSD");
        assertEq(_arcUSDToken.rebaseIndex(), 1 ether);

        instance2.initialize(address(2), address(3));
        assertEq(_arcUSDToken.name(), "arcUSD");
        assertEq(_arcUSDToken.symbol(), "arcUSD");
        assertEq(_arcUSDToken.rebaseIndex(), 1 ether);
    }

    function test_arcUSDToken_isUpgradeable() public {
        arcUSD newImplementation = new arcUSD(block.chainid, address(1));

        bytes32 implementationSlot =
            vm.load(address(_arcUSDToken), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        _arcUSDToken.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(_arcUSDToken), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_arcUSDToken_isUpgradeable_onlyOwner() public {
        arcUSD newImplementation = new arcUSD(block.chainid, address(1));

        vm.prank(_minter);
        vm.expectRevert();
        _arcUSDToken.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        _arcUSDToken.upgradeToAndCall(address(newImplementation), "");
    }

    function testownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(CantRenounceOwnershipErr);
        _arcUSDToken.renounceOwnership();
        assertEq(_arcUSDToken.owner(), owner);
        assertNotEq(_arcUSDToken.owner(), address(0));
    }

    function test_CanTransferOwnership() public {
        vm.prank(owner);
        _arcUSDToken.transferOwnership(_newOwner);
        assertEq(_arcUSDToken.owner(), _newOwner);
    }

    function test_NewOwnerCanPerformOwnerActions() public {
        vm.prank(owner);
        _arcUSDToken.transferOwnership(_newOwner);
        vm.startPrank(_newOwner);
        _arcUSDToken.setMinter(_newMinter);
        vm.stopPrank();
        assertEq(_arcUSDToken.minter(), _newMinter);
        assertNotEq(_arcUSDToken.minter(), _minter);
    }

    function test_OnlyOwnerCanSetMinter() public {
        vm.prank(_newOwner);
        vm.expectRevert();
        _arcUSDToken.setMinter(_newMinter);
        assertEq(_arcUSDToken.minter(), _minter);
    }

    function test_OnlyOwnerCanSetRebaseManager() public {
        vm.prank(_newOwner);
        vm.expectRevert();
        _arcUSDToken.setRebaseManager(_newRebaseManager);
        assertEq(_arcUSDToken.rebaseManager(), _rebaseManager);
        vm.prank(owner);
        _arcUSDToken.setRebaseManager(_newRebaseManager);
        assertEq(_arcUSDToken.rebaseManager(), _newRebaseManager);
    }

    function testownerCantMint() public {
        vm.prank(owner);
        vm.expectRevert(OnlyMinterErr);
        _arcUSDToken.mint(_newMinter, 100);
    }

    function test_MinterCanMint() public {
        assertEq(_arcUSDToken.balanceOf(_newMinter), 0);
        vm.prank(_minter);
        _arcUSDToken.mint(_newMinter, 100);
        assertEq(_arcUSDToken.balanceOf(_newMinter), 100);
    }

    function test_MinterCantMintToZeroAddress() public {
        vm.prank(_minter);
        vm.expectRevert();
        _arcUSDToken.mint(address(0), 100);
    }

    function test_NewMinterCanMint() public {
        assertEq(_arcUSDToken.balanceOf(_newMinter), 0);
        vm.prank(owner);
        _arcUSDToken.setMinter(_newMinter);
        vm.prank(_newMinter);
        _arcUSDToken.mint(_newMinter, 100);
        assertEq(_arcUSDToken.balanceOf(_newMinter), 100);
    }

    function test_OldMinterCantMint() public {
        assertEq(_arcUSDToken.balanceOf(_newMinter), 0);
        vm.prank(owner);
        _arcUSDToken.setMinter(_newMinter);
        vm.prank(_minter);
        vm.expectRevert(OnlyMinterErr);
        _arcUSDToken.mint(_newMinter, 100);
        assertEq(_arcUSDToken.balanceOf(_newMinter), 0);
    }

    function test_OldOwnerCantTransferOwnership() public {
        vm.prank(owner);
        _arcUSDToken.transferOwnership(_newOwner);
        vm.prank(_newOwner);
        assertNotEq(_arcUSDToken.owner(), owner);
        assertEq(_arcUSDToken.owner(), _newOwner);
        vm.prank(owner);
        vm.expectRevert();
        _arcUSDToken.transferOwnership(_newMinter);
        assertEq(_arcUSDToken.owner(), _newOwner);
    }

    function test_OldOwnerCantSetMinter() public {
        vm.prank(owner);
        _arcUSDToken.transferOwnership(_newOwner);
        assertEq(_arcUSDToken.owner(), _newOwner);
        vm.expectRevert();
        _arcUSDToken.setMinter(_newMinter);
        assertEq(_arcUSDToken.minter(), _minter);
    }
}
