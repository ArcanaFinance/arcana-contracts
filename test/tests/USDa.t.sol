// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable private-vars-leading-underscore  */

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";
import {SigUtils} from "../utils/SigUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {USDa} from "../../src/USDa.sol";
import {USDaTaxManager} from "../../src/USDaTaxManager.sol";
import {BaseSetup} from "../BaseSetup.sol";

contract USDaTest is Test, BaseSetup {
    USDa internal _usdaToken;
    USDaTaxManager internal _taxManager;

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

        _usdaToken = new USDa(31337, _layerZeroEndpoint);
        ERC1967Proxy _usdaTokenProxy = new ERC1967Proxy(
            address(_usdaToken), abi.encodeWithSelector(USDa.initialize.selector, owner, _rebaseManager)
        );
        _usdaToken = USDa(address(_usdaTokenProxy));

        _taxManager = new USDaTaxManager(owner, address(_usdaToken), _feeCollector);

        vm.prank(owner);
        _usdaToken.setMinter(_minter);

        vm.prank(owner);
        _usdaToken.setSupplyLimit(type(uint256).max);

        vm.prank(owner);
        _usdaToken.setTaxManager(address(_taxManager));
    }

    function test_CorrectInitialConfig() public {
        assertEq(_usdaToken.owner(), owner);
        assertEq(_usdaToken.minter(), _minter);
        assertEq(_usdaToken.rebaseManager(), _rebaseManager);
        assertEq(address(_usdaToken.lzEndpoint()), _layerZeroEndpoint);
        assertEq(_usdaToken.isMainChain(), true);
    }

    function test_initialize() public {
        uint256 mainChainId = block.chainid;
        uint256 sideChainId = mainChainId + 1;

        USDa instance1 = new USDa(mainChainId, address(1));

        vm.chainId(sideChainId);

        USDa instance2 = new USDa(mainChainId, address(1));

        bytes32 slot = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1))
            & ~bytes32(uint256(0xff));
        vm.store(address(instance1), slot, 0);
        vm.store(address(instance2), slot, 0);

        instance1.initialize(address(2), address(3));
        assertEq(_usdaToken.name(), "USDa");
        assertEq(_usdaToken.symbol(), "USDa");
        assertEq(_usdaToken.rebaseIndex(), 1 ether);

        instance2.initialize(address(2), address(3));
        assertEq(_usdaToken.name(), "USDa");
        assertEq(_usdaToken.symbol(), "USDa");
        assertEq(_usdaToken.rebaseIndex(), 1 ether);
    }

    function test_usdaToken_isUpgradeable() public {
        USDa newImplementation = new USDa(block.chainid, address(1));

        bytes32 implementationSlot =
            vm.load(address(_usdaToken), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        _usdaToken.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(_usdaToken), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_usdaToken_isUpgradeable_onlyOwner() public {
        USDa newImplementation = new USDa(block.chainid, address(1));

        vm.prank(_minter);
        vm.expectRevert();
        _usdaToken.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        _usdaToken.upgradeToAndCall(address(newImplementation), "");
    }

    function testownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(CantRenounceOwnershipErr);
        _usdaToken.renounceOwnership();
        assertEq(_usdaToken.owner(), owner);
        assertNotEq(_usdaToken.owner(), address(0));
    }

    function test_CanTransferOwnership() public {
        vm.prank(owner);
        _usdaToken.transferOwnership(_newOwner);
        assertEq(_usdaToken.owner(), _newOwner);
    }

    function test_NewOwnerCanPerformOwnerActions() public {
        vm.prank(owner);
        _usdaToken.transferOwnership(_newOwner);
        vm.startPrank(_newOwner);
        _usdaToken.setMinter(_newMinter);
        vm.stopPrank();
        assertEq(_usdaToken.minter(), _newMinter);
        assertNotEq(_usdaToken.minter(), _minter);
    }

    function test_OnlyOwnerCanSetMinter() public {
        vm.prank(_newOwner);
        vm.expectRevert();
        _usdaToken.setMinter(_newMinter);
        assertEq(_usdaToken.minter(), _minter);
    }

    function test_OnlyOwnerCanSetRebaseManager() public {
        vm.prank(_newOwner);
        vm.expectRevert();
        _usdaToken.setRebaseManager(_newRebaseManager);
        assertEq(_usdaToken.rebaseManager(), _rebaseManager);
        vm.prank(owner);
        _usdaToken.setRebaseManager(_newRebaseManager);
        assertEq(_usdaToken.rebaseManager(), _newRebaseManager);
    }

    function testownerCantMint() public {
        vm.prank(owner);
        vm.expectRevert(OnlyMinterErr);
        _usdaToken.mint(_newMinter, 100);
    }

    function test_MinterCanMint() public {
        assertEq(_usdaToken.balanceOf(_newMinter), 0);
        vm.prank(_minter);
        _usdaToken.mint(_newMinter, 100);
        assertEq(_usdaToken.balanceOf(_newMinter), 100);
    }

    function test_MinterCantMintToZeroAddress() public {
        vm.prank(_minter);
        vm.expectRevert();
        _usdaToken.mint(address(0), 100);
    }

    function test_NewMinterCanMint() public {
        assertEq(_usdaToken.balanceOf(_newMinter), 0);
        vm.prank(owner);
        _usdaToken.setMinter(_newMinter);
        vm.prank(_newMinter);
        _usdaToken.mint(_newMinter, 100);
        assertEq(_usdaToken.balanceOf(_newMinter), 100);
    }

    function test_OldMinterCantMint() public {
        assertEq(_usdaToken.balanceOf(_newMinter), 0);
        vm.prank(owner);
        _usdaToken.setMinter(_newMinter);
        vm.prank(_minter);
        vm.expectRevert(OnlyMinterErr);
        _usdaToken.mint(_newMinter, 100);
        assertEq(_usdaToken.balanceOf(_newMinter), 0);
    }

    function test_OldOwnerCantTransferOwnership() public {
        vm.prank(owner);
        _usdaToken.transferOwnership(_newOwner);
        vm.prank(_newOwner);
        assertNotEq(_usdaToken.owner(), owner);
        assertEq(_usdaToken.owner(), _newOwner);
        vm.prank(owner);
        vm.expectRevert();
        _usdaToken.transferOwnership(_newMinter);
        assertEq(_usdaToken.owner(), _newOwner);
    }

    function test_OldOwnerCantSetMinter() public {
        vm.prank(owner);
        _usdaToken.transferOwnership(_newOwner);
        assertEq(_usdaToken.owner(), _newOwner);
        vm.expectRevert();
        _usdaToken.setMinter(_newMinter);
        assertEq(_usdaToken.minter(), _minter);
    }
}
