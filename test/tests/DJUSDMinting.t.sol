// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

import {BaseSetup} from "../BaseSetup.sol";
import {DJUSDMinter} from "../../src/DJUSDMinter.sol";
import {MockToken} from "../mock/MockToken.sol";
import {DJUSD} from "../../src/DJUSD.sol";
import {IDJUSD} from "../../src/interfaces/IDJUSD.sol";
import {DJUSDTaxManager} from "../../src/DJUSDTaxManager.sol";
import {IDJUSDDefinitions} from "../../src/interfaces/IDJUSDDefinitions.sol";
import {CommonErrors} from "../../src/interfaces/CommonErrors.sol";

/**
 * @title DJUSDMinterCoreTest
 * @notice Unit Tests for DJUSDMinter contract interactions
 */
contract DJUSDMinterCoreTest is BaseSetup, CommonErrors {
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();
    }

    function test_init_state() public {
        assertNotEq(djUsdToken.taxManager(), address(0));

        address[] memory assets = djUsdMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        assertEq(djUsdMinter.custodian(), address(custodian));
    }

    function test_djusdMinting_isUpgradeable() public {
        DJUSDMinter newImplementation = new DJUSDMinter(IDJUSD(address(djUsdToken)));

        bytes32 implementationSlot =
            vm.load(address(djUsdMinter), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        djUsdMinter.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(djUsdMinter), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_djusdMinting_isUpgradeable_onlyOwner() public {
        DJUSDMinter newImplementation = new DJUSDMinter(IDJUSD(address(djUsdToken)));

        vm.prank(minter);
        vm.expectRevert();
        djUsdMinter.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        djUsdMinter.upgradeToAndCall(address(newImplementation), "");
    }

    function test_unsupported_assets_ERC20_revert() public {
        vm.startPrank(owner);
        djUsdMinter.removeSupportedAsset(address(USTB));
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMinter), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        djUsdMinter.mint(address(USTB), _amountToDeposit, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_unsupported_assets_ETH_revert() public {
        vm.startPrank(owner);
        vm.deal(bob, _amountToDeposit);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMinter), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        djUsdMinter.mint(NATIVE_TOKEN, _amountToDeposit, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_add_and_remove_supported_asset() public {
        address asset = address(20);
        address oracle = address(21);
        vm.startPrank(owner);
        djUsdMinter.addSupportedAsset(asset, oracle);
        assertTrue(djUsdMinter.isSupportedAsset(asset));

        djUsdMinter.removeSupportedAsset(asset);
        assertFalse(djUsdMinter.isSupportedAsset(asset));
    }

    function test_cannot_add_asset_already_supported_revert() public {
        address asset = address(20);
        address oracle = address(21);
        vm.startPrank(owner);
        djUsdMinter.addSupportedAsset(asset, oracle);
        assertTrue(djUsdMinter.isSupportedAsset(asset));

        vm.expectRevert(abi.encodeWithSelector(AlreadyExists.selector, asset));
        djUsdMinter.addSupportedAsset(asset, oracle);
    }

    function test_cannot_removeAsset_not_supported_revert() public {
        address asset = address(20);
        assertFalse(djUsdMinter.isSupportedAsset(asset));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DJUSDMinter.NotSupportedAsset.selector, asset));
        djUsdMinter.removeSupportedAsset(asset);
    }

    function test_cannotAdd_addressZero_revert() public {
        vm.prank(owner);
        vm.expectRevert(InvalidZeroAddress.selector);
        djUsdMinter.addSupportedAsset(address(0), address(1));
    }

    function test_cannotAdd_DJUSD_revert() public {
        vm.prank(owner);
        vm.expectRevert();
        djUsdMinter.addSupportedAsset(address(djUsdToken), address(1));
    }

    function test_receive_eth() public {
        assertEq(address(djUsdMinter).balance, 0);
        vm.deal(owner, 10_000 ether);
        vm.prank(owner);
        (bool success,) = address(djUsdMinter).call{value: 10_000 ether}("");
        assertFalse(success);
        assertEq(address(djUsdMinter).balance, 0);
    }

    function test_mint_to_bob() public {
        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_mint_to_bob_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);
        deal(address(USTB), bob, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_requestTokens_to_alice_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_requestTokens_then_extendClaimTimestamp() public {
        // ~ config ~

        uint256 amount = 10 ether;

        uint256 newDelay = 10 days;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Custodian executes extendClaimTimestamp ~

        vm.prank(address(custodian));
        djUsdMinter.extendClaimTimestamp(alice, address(USTB), 0, uint48(block.timestamp + newDelay));

        // ~ Warp to original post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to new post-claimDelay and query claimable ~

        vm.warp(block.timestamp + newDelay);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_requestTokens_to_alice_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_requestTokens_to_alice_multiple() public {
        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint / 2;
        uint256 amount2 = amountToMint - amount1;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amountToMint);
        deal(address(USTB), address(djUsdMinter), amountToMint);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount1 + amount2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount1 + amount2);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens 1 ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount1);
        djUsdMinter.requestTokens(address(USTB), amount1);
        vm.stopPrank();

        uint256 request1 = block.timestamp;

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), amount2);
        assertEq(USTB.balanceOf(alice), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1);
        assertEq(claimable, 0);

        // ~ Alice executes requestTokens 2 ~

        vm.warp(block.timestamp + 1);

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount2);
        djUsdMinter.requestTokens(address(USTB), amount2);
        vm.stopPrank();

        uint256 request2 = block.timestamp;

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);
        assertEq(requests[1].amount, amount2);
        assertEq(requests[1].claimableAfter, request2 + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1 + amount2);
    }

    function test_claim_multiple_assets() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount * 2);
        deal(address(USTB), address(djUsdMinter), amount);
        deal(address(USDCToken), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount * 2);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);

        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USDCToken), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requestedUSTB = djUsdMinter.getPendingClaims(address(USTB));
        uint256 requestedUSDC = djUsdMinter.getPendingClaims(address(USDCToken));

        uint256 claimableUSTB = djUsdMinter.claimableTokens(alice, address(USTB));
        uint256 claimableUSDC = djUsdMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requestedUSTB = djUsdMinter.getPendingClaims(address(USTB));
        requestedUSDC = djUsdMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = djUsdMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = djUsdMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, amount);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USTB ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USTB), amount);

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), 0);
        assertEq(USDCToken.balanceOf(address(djUsdMinter)), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, 0);

        requestedUSTB = djUsdMinter.getPendingClaims(address(USTB));
        requestedUSDC = djUsdMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = djUsdMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = djUsdMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USDC ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USDCToken), amount);

        // ~ Post-state check 3 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requestedUSTB = djUsdMinter.getPendingClaims(address(USTB));
        requestedUSDC = djUsdMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = djUsdMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = djUsdMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, 0);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);
    }

    function test_claim_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USTB), amount);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMinter)), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_claim_partial() public {
        // ~ config ~

        uint256 amount = 10 ether;
        uint256 half = amount / 2;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims partial ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USTB), half);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), half);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount - half);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, half);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount - half);
        assertEq(claimable, amount - half);

        // ~ Alice claims the rest ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USTB), amount - half);

        // ~ Post-state check 3 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMinter)), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_claim_early_revert() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Alice claims ~

        // claims with 0 funds to be claimed, revert
        vm.prank(alice);
        vm.expectRevert();
        djUsdMinter.claimTokens(address(USTB), amount);

        deal(address(USTB), address(djUsdMinter), amount);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        // claims when it's too early, revert
        vm.prank(alice);
        vm.expectRevert();
        djUsdMinter.claimTokens(address(USTB), amount);
    }

    function test_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USTB), amount);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMinter)), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_mint_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.000000000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        vm.prank(address(djUsdMinter));
        djUsdToken.mint(bob, 1 ether);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (((preTotalSupply * 1e18) / djUsdToken.rebaseIndex()) * index) / 1e18;

        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 100);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // taker
        vm.startPrank(alice);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, 0);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 2);
    }

    function test_requestTokens_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
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
        deal(address(USTB), address(djUsdMinter), newBal);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), newBal);
        djUsdMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), newBal);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_requestTokens_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.0000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // mint
        vm.startPrank(alice);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
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
        deal(address(USTB), address(djUsdMinter), newBal);

        // taker
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), newBal);
        djUsdMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), newBal);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_claim_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
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
        deal(address(USTB), address(djUsdMinter), newBal);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMinter), newBal);
        djUsdMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMinter)), newBal);

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay() - 1);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMinter.claimDelay());

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);

        // ~ Alice claims ~

        vm.prank(alice);
        djUsdMinter.claimTokens(address(USTB), newBal);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), newBal);
        assertEq(USTB.balanceOf(address(djUsdMinter)), 0);

        requests = djUsdMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimed, newBal);

        requested = djUsdMinter.getPendingClaims(address(USTB));
        claimable = djUsdMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_supplyLimit() public {
        djUsdToken.setSupplyLimit(djUsdToken.totalSupply());

        vm.startPrank(bob);
        USTB.approve(address(djUsdMinter), _amountToDeposit);
        vm.expectRevert(LimitExceeded);
        djUsdMinter.mint(address(USTB), _amountToDeposit, _amountToDeposit);
        vm.stopPrank();
    }

    function test_mint_when_required() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);

        deal(address(USTB), alice, amount);

        vm.startPrank(bob);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(bob), 0);
        // USTB went to custodian
        assertEq(USTB.balanceOf(address(custodian)), amount);
        assertEq(USTB.balanceOf(address(djUsdMinter)), 0);
        assertEq(djUsdToken.balanceOf(bob), amount);

        // ~ bob requests tokens ~

        vm.startPrank(bob);
        djUsdToken.approve(address(djUsdMinter), amount);
        djUsdMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        uint256 requested = djUsdMinter.getPendingClaims(address(USTB));
        assertEq(requested, amount);

        // ~ alice mints DJUSD ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMinter), amount);
        djUsdMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
        // USTB stay in contract
        assertEq(USTB.balanceOf(address(djUsdMinter)), amount);
        assertEq(djUsdToken.balanceOf(alice), amount);
    }

    function test_setClaimDelay() public {
        // ~ Pre-state check ~

        assertEq(djUsdMinter.claimDelay(), 5 days);

        // ~ Execute setClaimDelay ~

        vm.prank(owner);
        djUsdMinter.setClaimDelay(7 days);

        // ~ Post-state check ~

        assertEq(djUsdMinter.claimDelay(), 7 days);
    }

    function test_updateCustodian() public {
        // ~ Pre-state check ~

        assertEq(djUsdMinter.custodian(), address(custodian));

        // ~ Execute setClaimDelay ~

        vm.prank(owner);
        djUsdMinter.updateCustodian(owner);

        // ~ Post-state check ~

        assertEq(djUsdMinter.custodian(), owner);
    }

    function test_restoreAsset() public {
        // ~ Pre-state check ~

        assertEq(djUsdMinter.isSupportedAsset(address(USTB)), true);

        address[] memory assets = djUsdMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        address[] memory allAssets = djUsdMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));

        // ~ Execute removeSupportedAsset ~

        vm.prank(owner);
        djUsdMinter.removeSupportedAsset(address(USTB));

        // ~ Post-state check 1 ~

        assertEq(djUsdMinter.isSupportedAsset(address(USTB)), false);

        assets = djUsdMinter.getActiveAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(USDCToken));
        assertEq(assets[1], address(USDTToken));

        allAssets = djUsdMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));

        // ~ Execute restoreAsset ~

        vm.prank(owner);
        djUsdMinter.restoreAsset(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdMinter.isSupportedAsset(address(USTB)), true);

        assets = djUsdMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        allAssets = djUsdMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));
    }

    function test_getRedemptionRequests() public {
        // ~ Config ~

        uint256 mintAmount = 1_000 * 1e18;
        uint256 numMints = 5;

        // mint DJUSD to an actor
        vm.prank(address(djUsdMinter));
        djUsdToken.mint(alice, mintAmount * numMints * 2);

        // ~ Pre-state check ~

        DJUSDMinter.RedemptionRequest[] memory requests = djUsdMinter.getRedemptionRequests(alice, 0, 10);
        assertEq(requests.length, 0);

        // ~ Execute requests for USTB ~

        for (uint256 i; i < numMints; ++i) {
            // requests for USTB
            vm.startPrank(alice);
            djUsdToken.approve(address(djUsdMinter), mintAmount);
            djUsdMinter.requestTokens(address(USTB), mintAmount);
            vm.stopPrank();
        }

        // ~ Post-state check 1 ~

        requests = djUsdMinter.getRedemptionRequests(alice, 0, 100);
        assertEq(requests.length, 5);

        // ~ Execute requests for USDC

        for (uint256 i; i < numMints; ++i) {
            // requests for USDC
            vm.startPrank(alice);
            djUsdToken.approve(address(djUsdMinter), mintAmount);
            djUsdMinter.requestTokens(address(USDCToken), mintAmount);
            vm.stopPrank();
        }

        // ~ Post-state check 2 ~

        requests = djUsdMinter.getRedemptionRequests(alice, 0, 100);
        assertEq(requests.length, 10);

        requests = djUsdMinter.getRedemptionRequests(alice, 0, 5);
        assertEq(requests.length, 5);
    }
}
