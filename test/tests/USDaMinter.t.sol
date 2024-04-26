// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {BaseSetup} from "../BaseSetup.sol";
import {USDaMinter} from "../../src/USDaMinter.sol";
import {MockToken} from "../mock/MockToken.sol";
import {USDa} from "../../src/USDa.sol";
import {IUSDa} from "../../src/interfaces/IUSDa.sol";
import {USDaTaxManager} from "../../src/USDaTaxManager.sol";
import {IUSDaDefinitions} from "../../src/interfaces/IUSDaDefinitions.sol";
import {CommonErrors} from "../../src/interfaces/CommonErrors.sol";

/**
 * @title USDaMinterCoreTest
 * @notice Unit Tests for USDaMinter contract interactions
 */
contract USDaMinterCoreTest is BaseSetup, CommonErrors {
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();
    }

    function test_init_state() public {
        assertNotEq(djUsdToken.taxManager(), address(0));

        address[] memory assets = usdaMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        assertEq(usdaMinter.custodian(), address(custodian));
    }

    function test_usdaMinter_initializer() public {
        USDaMinter newUSDaMinter = new USDaMinter(IUSDa(address(djUsdToken)));
        ERC1967Proxy newUSDaMinterProxy = new ERC1967Proxy(
            address(newUSDaMinter),
            abi.encodeWithSelector(USDaMinter.initialize.selector,
                owner,
                admin,
                whitelister,
                5 days
            )
        );
        newUSDaMinter = USDaMinter(payable(address(newUSDaMinterProxy)));

        assertEq(newUSDaMinter.owner(), owner);
        assertEq(newUSDaMinter.admin(), admin);
        assertEq(newUSDaMinter.whitelister(), whitelister);
        assertEq(newUSDaMinter.claimDelay(), 5 days);
        assertEq(newUSDaMinter.latestCoverageRatio(), 1e18);
    }

    function test_usdaMinter_isUpgradeable() public {
        USDaMinter newImplementation = new USDaMinter(IUSDa(address(djUsdToken)));

        bytes32 implementationSlot =
            vm.load(address(usdaMinter), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        usdaMinter.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(usdaMinter), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_usdaMinter_isUpgradeable_onlyOwner() public {
        USDaMinter newImplementation = new USDaMinter(IUSDa(address(djUsdToken)));

        vm.prank(minter);
        vm.expectRevert();
        usdaMinter.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        usdaMinter.upgradeToAndCall(address(newImplementation), "");
    }

    function test_usdaMinter_unsupported_assets_ERC20_revert() public {
        vm.startPrank(owner);
        usdaMinter.removeSupportedAsset(address(USTB));
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(usdaMinter), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        usdaMinter.mint(address(USTB), _amountToDeposit, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_usdaMinter_unsupported_assets_ETH_revert() public {
        vm.startPrank(owner);
        vm.deal(bob, _amountToDeposit);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(usdaMinter), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        usdaMinter.mint(NATIVE_TOKEN, _amountToDeposit, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_usdaMinter_add_and_remove_supported_asset() public {
        address asset = address(20);
        address oracle = address(21);
        vm.startPrank(owner);
        usdaMinter.addSupportedAsset(asset, oracle);
        assertTrue(usdaMinter.isSupportedAsset(asset));

        usdaMinter.removeSupportedAsset(asset);
        assertFalse(usdaMinter.isSupportedAsset(asset));
    }

    function test_usdaMinter_cannot_add_asset_already_supported_revert() public {
        address asset = address(20);
        address oracle = address(21);
        vm.startPrank(owner);
        usdaMinter.addSupportedAsset(asset, oracle);
        assertTrue(usdaMinter.isSupportedAsset(asset));

        vm.expectRevert(abi.encodeWithSelector(AlreadyExists.selector, asset));
        usdaMinter.addSupportedAsset(asset, oracle);
    }

    function test_usdaMinter_cannot_removeAsset_not_supported_revert() public {
        address asset = address(20);
        assertFalse(usdaMinter.isSupportedAsset(asset));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDaMinter.NotSupportedAsset.selector, asset));
        usdaMinter.removeSupportedAsset(asset);
    }

    function test_usdaMinter_cannotAdd_addressZero_revert() public {
        vm.prank(owner);
        vm.expectRevert(InvalidZeroAddress.selector);
        usdaMinter.addSupportedAsset(address(0), address(1));
    }

    function test_usdaMinter_cannotAdd_USDa_revert() public {
        vm.prank(owner);
        vm.expectRevert();
        usdaMinter.addSupportedAsset(address(djUsdToken), address(1));
    }

    function test_usdaMinter_receive_eth() public {
        assertEq(address(usdaMinter).balance, 0);
        vm.deal(owner, 10_000 ether);
        vm.prank(owner);
        (bool success,) = address(usdaMinter).call{value: 10_000 ether}("");
        assertFalse(success);
        assertEq(address(usdaMinter).balance, 0);
    }

    function test_usdaMinter_mint() public {
        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(usdaMinter), amount);
        usdaMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_usdaMinter_mint_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);
        deal(address(USTB), bob, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(usdaMinter), amount);
        usdaMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertEq(djUsdToken.balanceOf(bob), amount);
    }

    function test_usdaMinter_requestTokens_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        assertEq(usdaMinter.quoteRedeem(address(USTB), alice, amount), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_usdaMinter_requestTokens_then_extendClaimTimestamp() public {
        // ~ config ~

        uint256 amount = 10 ether;

        uint256 newDelay = 10 days;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Custodian executes extendClaimTimestamp ~

        vm.prank(admin);
        usdaMinter.extendClaimTimestamp(alice, address(USTB), 0, uint48(block.timestamp + newDelay));

        // ~ Warp to original post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to new post-claimDelay and query claimable ~

        vm.warp(block.timestamp + newDelay);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_usdaMinter_requestTokens_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        assertEq(usdaMinter.quoteRedeem(address(USTB), alice, amount), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_usdaMinter_requestTokens_multiple() public {
        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint / 2;
        uint256 amount2 = amountToMint - amount1;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amountToMint);
        deal(address(USTB), address(usdaMinter), amountToMint);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount1 + amount2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount1 + amount2);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens 1 ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount1);
        usdaMinter.requestTokens(address(USTB), amount1);
        vm.stopPrank();

        uint256 request1 = block.timestamp;

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), amount2);
        assertEq(USTB.balanceOf(alice), 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].asset, address(USTB));
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1);
        assertEq(claimable, 0);

        // ~ Alice executes requestTokens 2 ~

        vm.warp(block.timestamp + 1);

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount2);
        usdaMinter.requestTokens(address(USTB), amount2);
        vm.stopPrank();

        uint256 request2 = block.timestamp;

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].asset, address(USTB));
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);
        assertEq(requests[1].amount, amount2);
        assertEq(requests[1].asset, address(USTB));
        assertEq(requests[1].claimableAfter, request2 + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1 + amount2);
    }

    function test_usdaMinter_claim_multiple_assets() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount * 2);
        deal(address(USTB), address(usdaMinter), amount);
        deal(address(USDCToken), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount * 2);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);

        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USDCToken), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requestedUSTB = usdaMinter.getPendingClaims(address(USTB));
        uint256 requestedUSDC = usdaMinter.getPendingClaims(address(USDCToken));

        uint256 claimableUSTB = usdaMinter.claimableTokens(alice, address(USTB));
        uint256 claimableUSDC = usdaMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requestedUSTB = usdaMinter.getPendingClaims(address(USTB));
        requestedUSDC = usdaMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = usdaMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = usdaMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, amount);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USTB ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), 0);
        assertEq(USDCToken.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, 0);

        requestedUSTB = usdaMinter.getPendingClaims(address(USTB));
        requestedUSDC = usdaMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = usdaMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = usdaMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USDC ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USDCToken));

        // ~ Post-state check 3 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requestedUSTB = usdaMinter.getPendingClaims(address(USTB));
        requestedUSDC = usdaMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = usdaMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = usdaMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, 0);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);
    }

    function test_usdaMinter_claim_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(usdaMinter)), 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_usdaMinter_claim_early_revert() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Alice claims ~

        // claims with 0 funds to be claimed, revert
        vm.prank(alice);
        vm.expectRevert();
        usdaMinter.claimTokens(address(USTB));

        deal(address(USTB), address(usdaMinter), amount);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        // claims when it's too early, revert
        assertEq(usdaMinter.claimableTokens(alice, address(USTB)), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(USDaMinter.NoTokensClaimable.selector));
        usdaMinter.claimTokens(address(USTB));
    }

    function test_usdaMinter_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(usdaMinter)), 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_usdaMinter_mint_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.000000000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        vm.prank(address(usdaMinter));
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
        USTB.approve(address(usdaMinter), amount);
        usdaMinter.mint(address(USTB), amount, 0);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 2);
    }

    function test_usdaMinter_requestTokens_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(usdaMinter), amount);
        usdaMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on USDa ~

        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * djUsdToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(usdaMinter), newBal);

        assertEq(usdaMinter.quoteRedeem(address(USTB), alice, newBal), newBal);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), newBal);
        usdaMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), newBal);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_usdaMinter_requestTokens_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.0000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // mint
        vm.startPrank(alice);
        USTB.approve(address(usdaMinter), amount);
        usdaMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
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
        deal(address(USTB), address(usdaMinter), newBal);

        // taker
        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), newBal);
        usdaMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), newBal);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_usdaMinter_claim_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(usdaMinter), amount);
        usdaMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on USDa ~

        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * djUsdToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(usdaMinter), newBal);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), newBal);
        usdaMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), newBal);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + usdaMinter.claimDelay() - 1);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), newBal);
        assertEq(USTB.balanceOf(address(usdaMinter)), 0);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimed, newBal);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_usdaMinter_supplyLimit() public {
        djUsdToken.setSupplyLimit(djUsdToken.totalSupply());

        vm.startPrank(bob);
        USTB.approve(address(usdaMinter), _amountToDeposit);
        vm.expectRevert(LimitExceeded);
        usdaMinter.mint(address(USTB), _amountToDeposit, _amountToDeposit);
        vm.stopPrank();
    }

    function test_usdaMinter_withdrawFunds() public {
        // ~ Config ~

        uint256 amount = 10 * 1e18;
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertEq(USTB.balanceOf(address(custodian)), 0);

        // ~ Custodian calls withdrawFunds ~

        vm.prank(address(custodian));
        usdaMinter.withdrawFunds(address(USTB), amount);

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(address(usdaMinter)), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
    }

    function test_usdaMinter_withdrawFunds_partial() public {
        // ~ Config ~

        uint256 amount = 10 * 1e18;
        uint256 amountClaim = 5 * 1e18;
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(address(usdaMinter)), amount);
        assertEq(USTB.balanceOf(address(custodian)), 0);

        // ~ Custodian calls withdrawFunds ~

        vm.prank(address(custodian));
        usdaMinter.withdrawFunds(address(USTB), amountClaim);

        // ~ Pre-state check 1 ~

        assertEq(USTB.balanceOf(address(usdaMinter)), amount - amountClaim);
        assertEq(USTB.balanceOf(address(custodian)), amountClaim);

        // ~ Custodian calls withdrawFunds ~

        vm.prank(address(custodian));
        usdaMinter.withdrawFunds(address(USTB), amountClaim);

        // ~ Pre-state check 2 ~

        assertEq(USTB.balanceOf(address(usdaMinter)), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
    }

    function test_usdaMinter_withdrawFunds_restrictions() public {
        uint256 amount = 10 ether;

        // only custodian
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(USDaMinter.NotCustodian.selector, bob));
        usdaMinter.withdrawFunds(address(USTB), amount);

        vm.prank(address(usdaMinter));
        djUsdToken.mint(bob, amount);
        vm.startPrank(bob);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();
        assertEq(usdaMinter.requiredTokens(address(USTB)), amount);

        // required > bal -> No funds to withdraw
        vm.prank(address(custodian));
        vm.expectRevert(abi.encodeWithSelector(USDaMinter.NoFundsWithdrawable.selector, amount, 0));
        usdaMinter.withdrawFunds(address(USTB), amount);
    }

    function test_usdaMinter_setClaimDelay() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.claimDelay(), 5 days);

        // ~ Execute setClaimDelay ~

        vm.prank(owner);
        usdaMinter.setClaimDelay(7 days);

        // ~ Post-state check ~

        assertEq(usdaMinter.claimDelay(), 7 days);
    }

    function test_usdaMinter_updateCustodian() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.custodian(), address(custodian));

        // ~ Execute setClaimDelay ~

        vm.prank(owner);
        usdaMinter.updateCustodian(owner);

        // ~ Post-state check ~

        assertEq(usdaMinter.custodian(), owner);
    }

    function test_usdaMinter_restoreAsset() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.isSupportedAsset(address(USTB)), true);

        address[] memory assets = usdaMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        address[] memory allAssets = usdaMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));

        // ~ Execute removeSupportedAsset ~

        vm.prank(owner);
        usdaMinter.removeSupportedAsset(address(USTB));

        // ~ Post-state check 1 ~

        assertEq(usdaMinter.isSupportedAsset(address(USTB)), false);

        assets = usdaMinter.getActiveAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(USDCToken));
        assertEq(assets[1], address(USDTToken));

        allAssets = usdaMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));

        // ~ Execute restoreAsset ~

        vm.prank(owner);
        usdaMinter.restoreAsset(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(usdaMinter.isSupportedAsset(address(USTB)), true);

        assets = usdaMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        allAssets = usdaMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));
    }

    function test_usdaMinter_getRedemptionRequests() public {
        // ~ Config ~

        uint256 mintAmount = 1_000 * 1e18;
        uint256 numMints = 5;

        // mint USDa to an actor
        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, mintAmount * numMints * 2);

        // ~ Pre-state check ~

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, 0, 10);
        assertEq(requests.length, 0);

        // ~ Execute requests for USTB ~

        for (uint256 i; i < numMints; ++i) {
            // requests for USTB
            vm.startPrank(alice);
            djUsdToken.approve(address(usdaMinter), mintAmount);
            usdaMinter.requestTokens(address(USTB), mintAmount);
            vm.stopPrank();
        }

        // ~ Post-state check 1 ~

        requests = usdaMinter.getRedemptionRequests(alice, 0, 100);
        assertEq(requests.length, 5);

        // ~ Execute requests for USDC

        for (uint256 i; i < numMints; ++i) {
            // requests for USDC
            vm.startPrank(alice);
            djUsdToken.approve(address(usdaMinter), mintAmount);
            usdaMinter.requestTokens(address(USDCToken), mintAmount);
            vm.stopPrank();
        }

        // ~ Post-state check 2 ~

        requests = usdaMinter.getRedemptionRequests(alice, 0, 100);
        assertEq(requests.length, 10);

        requests = usdaMinter.getRedemptionRequests(alice, 0, 5);
        assertEq(requests.length, 5);
    }

    function test_usdaMinter_modifyWhitelist() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.isWhitelisted(bob), true);

        // ~ Execute modifyWhitelist ~

        vm.prank(whitelister);
        usdaMinter.modifyWhitelist(bob, false);

        // ~ Post-state check ~

        assertEq(usdaMinter.isWhitelisted(bob), false);
    }

    function test_usdaMinter_modifyWhitelist_restrictions() public {
        // only whitelister
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(USDaMinter.NotWhitelister.selector, bob));
        usdaMinter.modifyWhitelist(bob, false);

        // account cannot be address(0)
        vm.prank(whitelister);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        usdaMinter.modifyWhitelist(address(0), false);

        // cannot set status to status that's already set
        vm.prank(whitelister);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        usdaMinter.modifyWhitelist(bob, true);
    }

    function test_usdaMinter_coverageRatio() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.latestCoverageRatio(), 1 * 1e18);

        // ~ Execute setCoverageRatio ~

        skip(10);
        vm.prank(admin);
        usdaMinter.setCoverageRatio(.1 * 1e18);

        // ~ Post-state check ~

        assertEq(usdaMinter.latestCoverageRatio(), .1 * 1e18);
    }

    function test_usdaMinter_coverageRatio_restrictions() public {
        // only admin
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(USDaMinter.NotAdmin.selector, bob));
        usdaMinter.setCoverageRatio(.1 * 1e18);

        // ratio cannot be greater than 1e18
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, 1 * 1e18 + 1, 1 * 1e18));
        usdaMinter.setCoverageRatio(1 * 1e18 + 1);

        // cannot set ratio to already set ratio
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        usdaMinter.setCoverageRatio(1 * 1e18);
    }

    function test_usdaMinter_updateAdmin() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.admin(), admin);

        // ~ Execute updateAdmin ~

        vm.prank(owner);
        usdaMinter.updateAdmin(bob);

        // ~ Post-state check ~

        assertEq(usdaMinter.admin(), bob);
    }

    function test_usdaMinter_updateAdmin_restrictions() public {
        // only owner
        vm.prank(bob);
        vm.expectRevert();
        usdaMinter.updateAdmin(bob);

        // admin cannot be address(0)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        usdaMinter.updateAdmin(address(0));

        // cannot set to value already set
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        usdaMinter.updateAdmin(admin);
    }

    function test_usdaMinter_updateWhitelister() public {
        // ~ Pre-state check ~

        assertEq(usdaMinter.whitelister(), whitelister);

        // ~ Execute updateWhitelister ~

        vm.prank(owner);
        usdaMinter.updateWhitelister(bob);

        // ~ Post-state check ~

        assertEq(usdaMinter.whitelister(), bob);
    }

    function test_usdaMinter_updateWhitelister_restrictions() public {
        // only owner
        vm.prank(bob);
        vm.expectRevert();
        usdaMinter.updateWhitelister(bob);

        // whitelister cannot be address(0)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        usdaMinter.updateWhitelister(address(0));

        // cannot set to value already set
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        usdaMinter.updateWhitelister(whitelister);
    }

    function test_usdaMinter_claimable_coverageRatioSub1() public {
        // ~ config ~

        uint256 amount = 10 ether;
        uint256 ratio = .9 ether; // 90%

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // Warp to post-claimDelay and query claimable
        vm.warp(block.timestamp + usdaMinter.claimDelay());
        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));
        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        usdaMinter.setCoverageRatio(ratio);

        // ~ Post-state check ~

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));
        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amount * ratio / 1e18);
    }

    function test_usdaMinter_claimTokens_coverageRatioSub1() public {
        // ~ config ~

        uint256 amount = 10 ether;
        uint256 ratio = .9 ether; // 90%

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        usdaMinter.setCoverageRatio(ratio);

        uint256 amountAfterRatio = amount * ratio / 1e18;

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amountAfterRatio);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount - amountAfterRatio);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_usdaMinter_claimTokens_coverageRatioSub1_fuzzing(uint256 ratio) public {
        ratio = bound(ratio, .01 ether, .9999 ether); // 1% -> 99.99%

        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount);
        deal(address(USTB), address(usdaMinter), amount);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        usdaMinter.setCoverageRatio(ratio);

        uint256 amountAfterRatio = amount * ratio / 1e18;

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amountAfterRatio);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount - amountAfterRatio);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_usdaMinter_claimTokens_coverageRatioSub1_multiple() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(usdaMinter));
        djUsdToken.mint(alice, amount*2);
        deal(address(USTB), address(usdaMinter), amount*2);

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount*2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount*2);

        USDaMinter.RedemptionRequest[] memory requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount*2);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = usdaMinter.getPendingClaims(address(USTB));
        uint256 claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        usdaMinter.setCoverageRatio(.9 ether);
        assertEq(usdaMinter.latestCoverageRatio(), .9 ether);

        uint256 ratio = usdaMinter.latestCoverageRatio();
        uint256 amountAfterRatio = amount * ratio / 1e18;

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amountAfterRatio);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount*2 - amountAfterRatio);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);

        // ~ alice requests another claim ~

        vm.startPrank(alice);
        djUsdToken.approve(address(usdaMinter), amount);
        usdaMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 3 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount*2 - amountAfterRatio);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);
        assertEq(requests[1].amount, amount);
        assertEq(requests[1].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        usdaMinter.setCoverageRatio(1 ether);
        assertEq(usdaMinter.latestCoverageRatio(), 1 ether);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + usdaMinter.claimDelay());

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        usdaMinter.claimTokens(address(USTB));

        // ~ Post-state check 4 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount + amountAfterRatio);
        assertEq(USTB.balanceOf(address(usdaMinter)), amount - amountAfterRatio);

        requests = usdaMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount);
        assertLt(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);
        assertEq(requests[1].amount, amount);
        assertEq(requests[1].claimableAfter, block.timestamp);
        assertEq(requests[1].claimed, amount);

        requested = usdaMinter.getPendingClaims(address(USTB));
        claimable = usdaMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_usdaMinter_quoteMint() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 newPrice = 1.2 * 1e18;

        assertEq(usdaMinter.quoteMint(address(USTB), bob, amountIn), amountIn);
        assertEq(USTBOracle.latestPrice(), 1 * 1e18);

        _changeOraclePrice(address(USTBOracle), newPrice);

        assertEq(usdaMinter.quoteMint(address(USTB), bob, amountIn), amountIn * newPrice / 1e18);
        assertEq(USTBOracle.latestPrice(), 1.2 * 1e18);
    }

    function test_usdaMinter_quoteRedeem() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 newPrice = 1.2 * 1e18;

        assertEq(usdaMinter.quoteRedeem(address(USTB), bob, amountIn), amountIn);
        assertEq(USTBOracle.latestPrice(), 1 * 1e18);

        _changeOraclePrice(address(USTBOracle), newPrice);

        assertEq(usdaMinter.quoteRedeem(address(USTB), bob, amountIn), amountIn * 1e18 / newPrice);
        assertEq(USTBOracle.latestPrice(), 1.2 * 1e18);
    }
}
