// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

import {BaseSetup} from "../BaseSetup.sol";
import {DJUSDMinting} from "../../src/DJUSDMinting.sol";
import {MockToken} from "../../src/mock/MockToken.sol";
import {DJUSD} from "../../src/DJUSD.sol";
import {IDJUSD} from "../../src/interfaces/IDJUSD.sol";
import {DJUSDTaxManager} from "../../src/DJUSDTaxManager.sol";
import {IDJUSDDefinitions} from "../../src/interfaces/IDJUSDDefinitions.sol";

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

        assertEq(djUsdMintingContract.custodian(), custodian1);
    }

    function test_djusdMinting_isUpgradeable() public {
        DJUSDMinting newImplementation = new DJUSDMinting(IDJUSD(address(djUsdToken)));

        bytes32 implementationSlot =
            vm.load(address(djUsdMintingContract), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        djUsdMintingContract.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(djUsdMintingContract), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_djusdMinting_isUpgradeable_onlyOwner() public {
        DJUSDMinting newImplementation = new DJUSDMinting(IDJUSD(address(djUsdToken)));

        vm.prank(minter);
        vm.expectRevert();
        djUsdMintingContract.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        djUsdMintingContract.upgradeToAndCall(address(newImplementation), "");
    }

    function test_unsupported_assets_ERC20_revert() public {
        vm.startPrank(owner);
        djUsdMintingContract.removeSupportedAsset(address(USTB));
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        djUsdMintingContract.mint(address(USTB), _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_unsupported_assets_ETH_revert() public {
        vm.startPrank(owner);
        vm.deal(bob, _amountToDeposit);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        djUsdMintingContract.mint(NATIVE_TOKEN, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_add_and_remove_supported_asset() public {
        address asset = address(20);
        vm.startPrank(owner);
        djUsdMintingContract.addSupportedAsset(asset);
        assertTrue(djUsdMintingContract.isSupportedAsset(asset));

        djUsdMintingContract.removeSupportedAsset(asset);
        assertFalse(djUsdMintingContract.isSupportedAsset(asset));
    }

    function test_cannot_add_asset_already_supported_revert() public {
        address asset = address(20);
        vm.startPrank(owner);
        djUsdMintingContract.addSupportedAsset(asset);
        assertTrue(djUsdMintingContract.isSupportedAsset(asset));

        vm.expectRevert();
        djUsdMintingContract.addSupportedAsset(asset);
    }

    function test_cannot_removeAsset_not_supported_revert() public {
        address asset = address(20);
        assertFalse(djUsdMintingContract.isSupportedAsset(asset));

        vm.prank(owner);
        vm.expectRevert();
        djUsdMintingContract.removeSupportedAsset(asset);
    }

    function test_cannotAdd_addressZero_revert() public {
        vm.prank(owner);
        vm.expectRevert();
        djUsdMintingContract.addSupportedAsset(address(0));
    }

    function test_cannotAdd_DJUSD_revert() public {
        vm.prank(owner);
        vm.expectRevert();
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

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_mint_to_bob_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);
        deal(address(USTB), bob, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_requestTokens_to_alice_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_requestTokens_to_alice_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_requestTokens_to_alice_multiple() public {
        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint / 2;
        uint256 amount2 = amountToMint - amount1;

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amountToMint);
        deal(address(USTB), address(djUsdMintingContract), amountToMint);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount1 + amount2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount1 + amount2);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens 1 ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount1);
        djUsdMintingContract.requestTokens(address(USTB), amount1);
        vm.stopPrank();

        uint256 request1 = block.timestamp;

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), amount2);
        assertEq(USTB.balanceOf(alice), 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1);
        assertEq(claimable, 0);

        // ~ Alice executes requestTokens 2 ~

        vm.warp(block.timestamp + 1);

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount2);
        djUsdMintingContract.requestTokens(address(USTB), amount2);
        vm.stopPrank();

        uint256 request2 = block.timestamp;

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);
        assertEq(requests[1].amount, amount2);
        assertEq(requests[1].claimableAfter, request2 + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1 + amount2);
    }

    function test_claim_multiple_assets() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount * 2);
        deal(address(USTB), address(djUsdMintingContract), amount);
        deal(address(USDCToken), address(djUsdMintingContract), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount * 2);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USDCToken));
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);

        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USDCToken), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USDCToken));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requestedUSTB = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 requestedUSDC = djUsdMintingContract.getPendingClaims(address(USDCToken));

        uint256 claimableUSTB = djUsdMintingContract.claimableTokens(alice, address(USTB));
        uint256 claimableUSDC = djUsdMintingContract.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requestedUSTB = djUsdMintingContract.getPendingClaims(address(USTB));
        requestedUSDC = djUsdMintingContract.getPendingClaims(address(USDCToken));

        claimableUSTB = djUsdMintingContract.claimableTokens(alice, address(USTB));
        claimableUSDC = djUsdMintingContract.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, amount);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USTB ~

        vm.prank(alice);
        djUsdMintingContract.claimTokens(address(USTB), amount);

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), 0);
        assertEq(USDCToken.balanceOf(address(djUsdMintingContract)), amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USDCToken));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, 0);

        requestedUSTB = djUsdMintingContract.getPendingClaims(address(USTB));
        requestedUSDC = djUsdMintingContract.getPendingClaims(address(USDCToken));

        claimableUSTB = djUsdMintingContract.claimableTokens(alice, address(USTB));
        claimableUSDC = djUsdMintingContract.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USDC ~

        vm.prank(alice);
        djUsdMintingContract.claimTokens(address(USDCToken), amount);

        // ~ Post-state check 3 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USDCToken));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requestedUSTB = djUsdMintingContract.getPendingClaims(address(USTB));
        requestedUSDC = djUsdMintingContract.getPendingClaims(address(USDCToken));

        claimableUSTB = djUsdMintingContract.claimableTokens(alice, address(USTB));
        claimableUSDC = djUsdMintingContract.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, 0);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);
    }

    function test_claim_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        djUsdMintingContract.claimTokens(address(USTB), amount);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_claim_early_revert() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Alice claims ~

        // claims with 0 funds to be claimed, revert
        vm.prank(alice);
        vm.expectRevert();
        djUsdMintingContract.claimTokens(address(USTB), amount);

        deal(address(USTB), address(djUsdMintingContract), amount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // claims when it's too early, revert
        vm.prank(alice);
        vm.expectRevert();
        djUsdMintingContract.claimTokens(address(USTB), amount);
    }

    function test_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(djUsdMintingContract), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        djUsdMintingContract.claimTokens(address(USTB), amount);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
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

        // taker
        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 2);
    }

    function test_requestTokens_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
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

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), newBal);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

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
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
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

        // taker
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), newBal);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

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
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
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

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), newBal);

        DJUSDMinting.RedemptionRequest[] memory requests =
            djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        uint256 claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);

        // ~ Alice claims ~

        vm.prank(alice);
        djUsdMintingContract.claimTokens(address(USTB), newBal);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), newBal);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);

        requests = djUsdMintingContract.getRedemptionRequests(alice, address(USTB));
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimed, newBal);

        requested = djUsdMintingContract.getPendingClaims(address(USTB));
        claimable = djUsdMintingContract.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_supplyLimit() public {
        djUsdToken.setSupplyLimit(djUsdToken.totalSupply());

        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.expectRevert(LimitExceeded);
        djUsdMintingContract.mint(address(USTB), _amountToDeposit);
        vm.stopPrank();
    }

    function test_mint_when_required() public {
        // ~ Config ~

        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);
        deal(address(USTB), alice, amount);

        vm.startPrank(bob);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(bob), 0);
        // USTB went to custodian
        assertEq(USTB.balanceOf(custodian1), amount);
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), 0);
        assertEq(djUsdToken.balanceOf(bob), amount);

        // ~ bob requests tokens ~

        vm.startPrank(bob);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        uint256 requested = djUsdMintingContract.getPendingClaims(address(USTB));
        assertEq(requested, amount);

        // ~ alice mints DJUSD ~

        vm.startPrank(alice);
        USTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(custodian1), amount);
        // USTB stay in contract
        assertEq(USTB.balanceOf(address(djUsdMintingContract)), amount);
        assertEq(djUsdToken.balanceOf(alice), amount);
    }
}
