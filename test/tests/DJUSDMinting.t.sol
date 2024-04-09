// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

import { BaseSetup } from "../BaseSetup.sol";
import { DJUSDMinting } from "../../src/DJUSDMinting.sol";
import { MockToken } from "../../src/mock/MockToken.sol";
import { DJUSD } from "../../src/DJUSD.sol";
import { DJUSDTaxManager } from "../../src/DJUSDTaxManager.sol";
import { IDJUSDMinting } from "../../src/interfaces/IDJUSDMinting.sol";
import { IDJUSDMintingEvents } from "../../src/interfaces/IDJUSDMintingEvents.sol";
import { IDJUSDDefinitions } from "../../src/interfaces/IDJUSDDefinitions.sol";

/**
 * @title DJUSDMintingCoreTest
 * @notice Unit Tests for DJUSDMinting contract interactions
 */
contract DJUSDMintingCoreTest is BaseSetup {

    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();
    }

    function test_init_state() public {
        assertNotEq(djUsdToken.taxManager(), address(0));

        address[] memory assets = djUsdMintingContract.getAllSupportedAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        address[] memory custodians = djUsdMintingContract.getAllCustodians();
        assertEq(custodians.length, 2);
        assertEq(custodians[0], custodian1);
        assertEq(custodians[1], address(djUsdMintingContract));

        assertEq(djUsdMintingContract.isCustodianAddress(custodian1), true);
    }

    function test_djusdMinting_isUpgradeable() public {
        DJUSDMinting newImplementation = new DJUSDMinting();

        bytes32 implementationSlot = vm.load(address(djUsdMintingContract), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        djUsdMintingContract.upgradeToAndCall(address(newImplementation), "");

        implementationSlot = vm.load(address(djUsdMintingContract), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_djusdMinting_isUpgradeable_onlyOwner() public {
        DJUSDMinting newImplementation = new DJUSDMinting();

        vm.prank(minter);
        vm.expectRevert();
        djUsdMintingContract.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        djUsdMintingContract.upgradeToAndCall(address(newImplementation), "");
    }

    function test_requestRedeem_invalidNonce_revert() public {
        IDJUSDMinting.Order memory redeemOrder = redeem_setup(_amountToDeposit, 1, false, bob);

        vm.startPrank(bob);
        djUsdMintingContract.requestRedeem(redeemOrder);

        vm.expectRevert(InvalidNonce);
        djUsdMintingContract.requestRedeem(redeemOrder);
    }

    function test_fuzz_mint_noSlippage(uint256 expectedAmount) public {
        uint256 preBal = USTB.balanceOf(bob);
        vm.assume(expectedAmount > 0 && expectedAmount < preBal);

        (
            IDJUSDMinting.Order memory order,
            IDJUSDMinting.Route memory route
        ) = mint_setup(expectedAmount, 1, false, bob);

        vm.recordLogs();
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);
        vm.getRecordedLogs();

        assertEq(USTB.balanceOf(bob), preBal - expectedAmount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), expectedAmount);
        assertEq(djUsdToken.balanceOf(bob), expectedAmount);
    }

    function test_multipleValid_custodyRatios_addresses() public {
        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 14,
            collateral_asset: address(USTB),
            collateral_amount: _amountToDeposit
        });

        address[] memory targets = new address[](3);
        targets[0] = address(djUsdMintingContract);
        targets[1] = custodian1;
        targets[2] = custodian2;

        uint256[] memory ratios = new uint256[](3);
        ratios[0] = 3_000;
        ratios[1] = 4_000;
        ratios[2] = 3_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), _amountToDeposit);

        vm.prank(bob);
        vm.expectRevert(InvalidRoute);
        djUsdMintingContract.mint(order, route);

        vm.prank(owner);
        djUsdMintingContract.addCustodianAddress(custodian2);

        vm.prank(bob);
        djUsdMintingContract.mint(order, route);

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(bob), _amountToDeposit);

        assertEq(USTB.balanceOf(address(custodian1)), (_amountToDeposit * 4) / 10);
        assertEq(USTB.balanceOf(address(custodian2)), (_amountToDeposit * 3) / 10);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), (_amountToDeposit * 3) / 10);

        // remove custodian and expect reversion
        vm.prank(owner);
        djUsdMintingContract.removeCustodianAddress(custodian2);

        vm.prank(bob);
        vm.expectRevert(InvalidRoute);
        djUsdMintingContract.mint(order, route);
    }

    function test_fuzz_multipleInvalid_custodyRatios_revert(uint256 ratio1) public {
        ratio1 = bound(ratio1, 0, UINT256_MAX - 7_000);
        vm.assume(ratio1 != 3_000);

        IDJUSDMinting.Order memory mintOrder = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 15,
            collateral_asset: address(USTB),
            collateral_amount: _amountToDeposit
        });

        address[] memory targets = new address[](2);
        targets[0] = address(djUsdMintingContract);
        targets[1] = owner;

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = ratio1;
        ratios[1] = 7_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), _amountToDeposit);

        vm.expectRevert(InvalidRoute);
        vm.prank(bob);
        djUsdMintingContract.mint(mintOrder, route);

        assertEq(USTB.balanceOf(bob), _amountToDeposit);
        assertEq(djUsdToken.balanceOf(bob), 0);

        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);
        assertEq(USTB.balanceOf(owner), 0);
    }

    function test_fuzz_singleInvalid_custodyRatio_revert(uint256 ratio1) public {
        vm.assume(ratio1 != 10_000);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 16,
            collateral_asset: address(USTB),
            collateral_amount: _amountToDeposit
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = ratio1;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), _amountToDeposit);

        vm.expectRevert(InvalidRoute);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);

        assertEq(USTB.balanceOf(bob), _amountToDeposit);
        assertEq(djUsdToken.balanceOf(bob), 0);

        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);
    }

    function test_unsupported_assets_ERC20_revert() public {
        vm.startPrank(owner);
        djUsdMintingContract.removeSupportedAsset(address(USTB));
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: _amountToDeposit
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert(UnsupportedAsset);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);
        vm.getRecordedLogs();
    }

    function test_unsupported_assets_ETH_revert() public {
        vm.startPrank(owner);
        vm.deal(bob, _amountToDeposit);
        vm.stopPrank();

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 19,
            collateral_asset: NATIVE_TOKEN,
            collateral_amount: _amountToDeposit
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert(UnsupportedAsset);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);
        vm.getRecordedLogs();
    }

    function test_expired_orders_revert() public {
        (
            IDJUSDMinting.Order memory order,
            IDJUSDMinting.Route memory route
        ) = mint_setup(_amountToDeposit, 1, false, bob);

        vm.warp(block.timestamp + 11 minutes);

        vm.recordLogs();
        vm.expectRevert(SignatureExpired);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);
        vm.getRecordedLogs();
    }

    function test_add_and_remove_supported_asset() public {
        address asset = address(20);
        vm.expectEmit(true, false, false, false);
        emit AssetAdded(asset);
        vm.startPrank(owner);
        djUsdMintingContract.addSupportedAsset(asset);
        assertTrue(djUsdMintingContract.isSupportedAsset(asset));

        vm.expectEmit(true, false, false, false);
        emit AssetRemoved(asset);
        djUsdMintingContract.removeSupportedAsset(asset);
        assertFalse(djUsdMintingContract.isSupportedAsset(asset));
    }

    function test_cannot_add_asset_already_supported_revert() public {
        address asset = address(20);
        vm.expectEmit(true, false, false, false);
        emit AssetAdded(asset);
        vm.startPrank(owner);
        djUsdMintingContract.addSupportedAsset(asset);
        assertTrue(djUsdMintingContract.isSupportedAsset(asset));

        vm.expectRevert(InvalidAssetAddress);
        djUsdMintingContract.addSupportedAsset(asset);
    }

    function test_cannot_removeAsset_not_supported_revert() public {
        address asset = address(20);
        assertFalse(djUsdMintingContract.isSupportedAsset(asset));

        vm.prank(owner);
        vm.expectRevert(InvalidAssetAddress);
        djUsdMintingContract.removeSupportedAsset(asset);
    }

    function test_cannotAdd_addressZero_revert() public {
        vm.prank(owner);
        vm.expectRevert(InvalidAssetAddress);
        djUsdMintingContract.addSupportedAsset(address(0));
    }

    function test_cannotAdd_DJUSD_revert() public {
        vm.prank(owner);
        vm.expectRevert(InvalidAssetAddress);
        djUsdMintingContract.addSupportedAsset(address(djUsdToken));
    }

    function test_receive_eth() public {
        assertEq(address(djUsdMintingContract).balance, 0);
        vm.deal(owner, 10_000 ether);
        vm.prank(owner);
        (bool success,) = address(djUsdMintingContract).call{value: 10_000 ether}("");
        assertFalse(success);
        assertEq(address(djUsdMintingContract).balance, 0);
    }

    function test_mint_to_bob() public {

        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_mint_to_bob_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);
        deal(address(USTB), bob, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_requestRedeem_to_alice_noFuzz() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, amount);
        assertEq(totalClaimableForAsset, amount);
        assertEq(totalClaimable, amount);
    }

    function test_requestRedeem_to_alice_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, amount);
        assertEq(totalClaimableForAsset, amount);
        assertEq(totalClaimable, amount);
    }

    function test_requestRedeem_to_alice_multiple_requests() public {

        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint/2;
        uint256 amount2 = amountToMint - amount1;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amountToMint);
        deal(address(USTB), address(djUsdMintingContract), amountToMint);

        IDJUSDMinting.Order memory order1 = IDJUSDMinting.Order({
            expiry: block.timestamp + 10,
            nonce: 1,
            collateral_asset: address(USTB),
            collateral_amount: amount1
        });

        IDJUSDMinting.Order memory order2 = IDJUSDMinting.Order({
            expiry: block.timestamp + 10,
            nonce: 2,
            collateral_asset: address(USTB),
            collateral_amount: amount2
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount1 + amount2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount1 + amount2);

        // ~ Alice executes requestRedeem 1 ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount1);
        djUsdMintingContract.requestRedeem(order1);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), amount2);
        assertEq(USTB.balanceOf(alice), 0);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1);
        assertEq(totalRequestedUSTB, amount1);
        assertEq(totalRequested, amount1);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Alice executes requestRedeem 2 ~

        vm.warp(block.timestamp + 1);
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount2);
        djUsdMintingContract.requestRedeem(order2);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1 + amount2);
        assertEq(totalRequestedUSTB, amount1 + amount2);
        assertEq(totalRequested, amount1 + amount2);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1 + amount2);
        assertEq(totalRequestedUSTB, amount1 + amount2);
        assertEq(totalRequested, amount1 + amount2);

        assertEq(claimableForAlice, amount1);
        assertEq(totalClaimableForAsset, amount1);
        assertEq(totalClaimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1 + amount2);
        assertEq(totalRequestedUSTB, amount1 + amount2);
        assertEq(totalRequested, amount1 + amount2);

        assertEq(claimableForAlice, amount1 + amount2);
        assertEq(totalClaimableForAsset, amount1 + amount2);
        assertEq(totalClaimable, amount1 + amount2);
    }

    function test_claim_multiple_asets() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount * 2);
        deal(address(USTB), address(djUsdMintingContract), amount);
        deal(address(USDCToken), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order1 = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        IDJUSDMinting.Order memory order2 = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 19,
            collateral_asset: address(USDCToken),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount*2);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order1);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order2);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);

        uint256 requestedUSTB = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 requestedUSDC = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USDCToken), uint48(block.timestamp));
        uint256 claimableForAliceUSTB = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 claimableForAliceUSDC = djUsdMintingContract.getClaimableForAccount(alice, address(USDCToken));
        uint256 totalClaimableForUSTB = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimableForUSDC = djUsdMintingContract.getTotalClaimableForAsset(address(USDCToken));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableForAliceUSTB, 0);
        assertEq(claimableForAliceUSDC, 0);
        assertEq(totalClaimableForUSTB, 0);
        assertEq(totalClaimableForUSDC, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requestedUSTB = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        requestedUSDC = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USDCToken), uint48(block.timestamp));
        claimableForAliceUSTB = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        claimableForAliceUSDC = djUsdMintingContract.getClaimableForAccount(alice, address(USDCToken));
        totalClaimableForUSTB = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimableForUSDC = djUsdMintingContract.getTotalClaimableForAsset(address(USDCToken));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableForAliceUSTB, amount);
        assertEq(claimableForAliceUSDC, amount);
        assertEq(totalClaimableForUSTB, amount);
        assertEq(totalClaimableForUSDC, amount);
        assertEq(totalClaimable, amount * 2);

        // ~ Alice claims USTB ~

        // reuse order1 to build claim order
        order1 = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        vm.prank(alice);
        djUsdMintingContract.claim(order1);

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(address(djUsdMintingContract)), amount);

        requestedUSTB = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        requestedUSDC = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USDCToken), uint48(block.timestamp));
        claimableForAliceUSTB = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        claimableForAliceUSDC = djUsdMintingContract.getClaimableForAccount(alice, address(USDCToken));
        totalClaimableForUSTB = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimableForUSDC = djUsdMintingContract.getTotalClaimableForAsset(address(USDCToken));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableForAliceUSTB, 0);
        assertEq(claimableForAliceUSDC, amount);
        assertEq(totalClaimableForUSTB, 0);
        assertEq(totalClaimableForUSDC, amount);
        assertEq(totalClaimable, amount);

        // ~ Alice claims USDC ~

        // reuse order1 to build claim order
        order1 = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USDCToken),
            collateral_amount: amount
        });

        vm.prank(alice);
        djUsdMintingContract.claim(order1);

        // ~ Post-state check 3 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), amount);

        requestedUSTB = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        requestedUSDC = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USDCToken), uint48(block.timestamp));
        claimableForAliceUSTB = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        claimableForAliceUSDC = djUsdMintingContract.getClaimableForAccount(alice, address(USDCToken));
        totalClaimableForUSTB = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimableForUSDC = djUsdMintingContract.getTotalClaimableForAsset(address(USDCToken));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableForAliceUSTB, 0);
        assertEq(claimableForAliceUSDC, 0);
        assertEq(totalClaimableForUSTB, 0);
        assertEq(totalClaimableForUSDC, 0);
        assertEq(totalClaimable, 0);
    }

    function test_claim_noFuzz() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, amount);
        assertEq(totalClaimableForAsset, amount);
        assertEq(totalClaimable, amount);

        // ~ Alice claims ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        vm.prank(alice);
        djUsdMintingContract.claim(order);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested - djUsdMintingContract.claimed(alice, address(USTB)), 0);
        assertEq(totalRequestedUSTB - djUsdMintingContract.totalClaimed(address(USTB)), 0);
        assertEq(totalRequested - djUsdMintingContract.totalClaimed(address(USTB)), 0);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);
    }

    function test_claim_early_revert() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Alice claims ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDJUSDMinting.NoAssetsClaimable.selector));
        djUsdMintingContract.claim(order);
    }

    function test_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, amount);
        assertEq(totalClaimableForAsset, amount);
        assertEq(totalClaimable, amount);

        // ~ Alice claims ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        vm.prank(alice);
        djUsdMintingContract.claim(order);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested - djUsdMintingContract.claimed(alice, address(USTB)), 0);
        assertEq(totalRequestedUSTB - djUsdMintingContract.totalClaimed(address(USTB)), 0);
        assertEq(totalRequested - djUsdMintingContract.totalClaimed(address(USTB)), 0);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);
    }

    function test_mint_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.000000000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(bob, 1 ether);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (((preTotalSupply * 1e18) / djUsdToken.rebaseIndex()) * index) / 1e18;

        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 100);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 2);
    }

    function test_requestRedeem_after_rebase_noFuzz() public {

        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 1,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on DJUSD ~
        
        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * djUsdToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(djUsdMintingContract), newBal);

        // ~ Alice executes requestRedeem ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 2,
            collateral_asset: address(USTB),
            collateral_amount: newBal
        });

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), newBal);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, newBal);
        assertEq(totalClaimableForAsset, newBal);
        assertEq(totalClaimable, newBal);
    }

    function test_requestRedeem_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.0000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 1,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // mint
        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;
        
        // setRebaseIndex
        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 100);
        uint256 newBal = amount * djUsdToken.rebaseIndex() / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(djUsdMintingContract), newBal);

        // redeem
        order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 2,
            collateral_asset: address(USTB),
            collateral_amount: newBal
        });

        // taker
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), newBal);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, newBal);
        assertEq(totalClaimableForAsset, newBal);
        assertEq(totalClaimable, newBal);
    }

    function test_claim_after_rebase_noFuzz() public {

        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 1,
            collateral_asset: address(USTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on DJUSD ~
        
        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * djUsdToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(djUsdMintingContract), newBal);

        // ~ Alice executes requestRedeem ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 2,
            collateral_asset: address(USTB),
            collateral_amount: newBal
        });

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), newBal);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, newBal);
        assertEq(totalClaimableForAsset, newBal);
        assertEq(totalClaimable, newBal);

        // ~ Alice claims ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(USTB),
            collateral_amount: newBal
        });

        vm.prank(alice);
        djUsdMintingContract.claim(order);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), newBal);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(USTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(USTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(USTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(USTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested - djUsdMintingContract.claimed(alice, address(USTB)), 0);
        assertEq(totalRequestedUSTB - djUsdMintingContract.totalClaimed(address(USTB)), 0);
        assertEq(totalRequested - djUsdMintingContract.totalClaimed(address(USTB)), 0);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);
    }

    function test_supplyLimit() public {
        djUsdToken.setSupplyLimit(djUsdToken.totalSupply());
        
        (
            IDJUSDMinting.Order memory order,
            IDJUSDMinting.Route memory route
        ) = mint_setup(_amountToDeposit, 1, false, bob);

        vm.prank(bob);
        vm.expectRevert(LimitExceeded);
        djUsdMintingContract.mint(order, route);
    }
}