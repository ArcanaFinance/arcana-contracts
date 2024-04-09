// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import { BaseSetup } from "../BaseSetup.sol";
import { DJUSDMinting } from "../../src/DJUSDMinting.sol";
import { DJUSD } from "../../src/DJUSD.sol";
import { DJUSDTaxManager } from "../../src/DJUSDTaxManager.sol";
import { IDJUSDMinting } from "../../src/interfaces/IDJUSDMinting.sol";
import { IDJUSDMintingEvents } from "../../src/interfaces/IDJUSDMintingEvents.sol";
import { IDJUSDDefinitions } from "../../src/interfaces/IDJUSDDefinitions.sol";

// helpers
import "../utils/Constants.sol";

/**
 * @title DJUSDMintingUSTBIntegrationTest
 * @notice Unit Tests for DJUSDMinting contract interactions
 */
contract DJUSDMintingUSTBIntegrationTest is BaseSetup {

    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    IERC20 public unrealUSTB = IERC20(UNREAL_USTB);

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();

        // remove unrealUSTB from supported assets and 

        vm.startPrank(owner);
        djUsdMintingContract.removeSupportedAsset(address(USTB));
        djUsdMintingContract.removeSupportedAsset(address(USDCToken));
        djUsdMintingContract.removeSupportedAsset(address(USDTToken));

        djUsdMintingContract.addSupportedAsset(address(unrealUSTB));
        djUsdMintingContract.optOutOfRebase(address(unrealUSTB), true);
        vm.stopPrank();
    }

    /// @dev local deal to take into account USTB's unique storage layout
    function _deal(address token, address give, uint256 amount) internal {
        // deal doesn't work with USTB since the storage layout is different
        if (token == address(unrealUSTB)) {
            // if address is opted out, update normal balance (basket is opted out of rebasing)
            if (give == address(djUsdMintingContract)) {
                bytes32 USTBStorageLocation = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;
                uint256 mapSlot = 0;
                bytes32 slot = keccak256(abi.encode(give, uint256(USTBStorageLocation) + mapSlot));
                vm.store(address(unrealUSTB), slot, bytes32(amount));
            }
            // else, update shares balance
            else {
                bytes32 USTBStorageLocation = 0x8a0c9d8ec1d9f8b365393c36404b40a33f47675e34246a2e186fbefd5ecd3b00;
                uint256 mapSlot = 2;
                bytes32 slot = keccak256(abi.encode(give, uint256(USTBStorageLocation) + mapSlot));
                vm.store(address(unrealUSTB), slot, bytes32(amount));
            }
        }
        // If not rebase token, use normal deal
        else {
            deal(token, give, amount);
        }
    }

    function test_USTB_init_state() public {
        assertNotEq(djUsdToken.taxManager(), address(0));

        address[] memory assets = djUsdMintingContract.getAllSupportedAssets();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(unrealUSTB));

        address[] memory custodians = djUsdMintingContract.getAllCustodians();
        assertEq(custodians.length, 2);
        assertEq(custodians[0], custodian1);
        assertEq(custodians[1], address(djUsdMintingContract));

        assertEq(djUsdMintingContract.isCustodianAddress(custodian1), true);
    }

    function test_USTB_multipleValid_custodyRatios_addresses() public {
        _deal(address(unrealUSTB), bob, 10 ether);
        uint256 amount = unrealUSTB.balanceOf(bob);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 14,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
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
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(bob), amount);

        vm.prank(bob);
        vm.expectRevert(InvalidRoute);
        djUsdMintingContract.mint(order, route);

        vm.prank(owner);
        djUsdMintingContract.addCustodianAddress(custodian2);

        vm.prank(bob);
        djUsdMintingContract.mint(order, route);

        assertEq(unrealUSTB.balanceOf(bob), 0);
        assertEq(djUsdToken.balanceOf(bob), amount);

        assertEq(unrealUSTB.balanceOf(address(custodian1)), (amount * 4) / 10);
        assertEq(unrealUSTB.balanceOf(address(custodian2)), (amount * 3) / 10);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), (amount * 3) / 10);

        // remove custodian and expect reversion
        vm.prank(owner);
        djUsdMintingContract.removeCustodianAddress(custodian2);

        vm.prank(bob);
        vm.expectRevert(InvalidRoute);
        djUsdMintingContract.mint(order, route);
    }

    function test_USTB_fuzz_multipleInvalid_custodyRatios_revert(uint256 ratio1) public {
        ratio1 = bound(ratio1, 0, UINT256_MAX - 7_000);
        vm.assume(ratio1 != 3_000);

        _deal(address(unrealUSTB), bob, 10 ether);
        uint256 amount = unrealUSTB.balanceOf(bob);

        IDJUSDMinting.Order memory mintOrder = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 15,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](2);
        targets[0] = address(djUsdMintingContract);
        targets[1] = custodian1;

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = ratio1;
        ratios[1] = 7_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        vm.startPrank(bob);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(bob), amount);

        vm.expectRevert(InvalidRoute);
        vm.prank(bob);
        djUsdMintingContract.mint(mintOrder, route);

        assertEq(unrealUSTB.balanceOf(bob), amount);
        assertEq(djUsdToken.balanceOf(bob), 0);

        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), 0);
        assertEq(unrealUSTB.balanceOf(custodian1), 0);
    }

    function test_USTB_fuzz_singleInvalid_custodyRatio_revert(uint256 ratio1) public {
        vm.assume(ratio1 != 10_000);

        _deal(address(unrealUSTB), bob, 10 ether);
        uint256 amount = unrealUSTB.balanceOf(bob);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 16,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = ratio1;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(bob), amount);

        vm.expectRevert(InvalidRoute);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);

        assertEq(unrealUSTB.balanceOf(bob), amount);
        assertEq(djUsdToken.balanceOf(bob), 0);

        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), 0);
    }

    function test_USTB_unsupported_assets_ERC20_revert() public {
        vm.startPrank(owner);
        djUsdMintingContract.removeSupportedAsset(address(unrealUSTB));
        _deal(address(unrealUSTB), bob, 10 ether);
        uint256 amount = unrealUSTB.balanceOf(bob);
        vm.stopPrank();

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert(UnsupportedAsset);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);
        vm.getRecordedLogs();
    }

    function test_USTB_unsupported_assets_ETH_revert() public {
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
        unrealUSTB.approve(address(djUsdMintingContract), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert(UnsupportedAsset);
        vm.prank(bob);
        djUsdMintingContract.mint(order, route);
        vm.getRecordedLogs();
    }

    function test_USTB_mint_to_bob() public {

        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), bob, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);

        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        uint256 preBal = unrealUSTB.balanceOf(bob);

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(bob), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount, 1);
        assertApproxEqAbs(djUsdToken.balanceOf(bob), amount, 1);
    }

    function test_USTB_mint_to_bob_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);
        _deal(address(unrealUSTB), bob, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        uint256 preBal = unrealUSTB.balanceOf(bob);

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertApproxEqAbs(unrealUSTB.balanceOf(bob), preBal - amount, 2);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount, 2);
        assertApproxEqAbs(djUsdToken.balanceOf(bob), amount, 2);
    }

    function test_USTB_requestRedeem_to_alice_noFuzz() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, amount);
        assertEq(totalClaimableForAsset, amount);
        assertEq(totalClaimable, amount);
    }

    function test_USTB_requestRedeem_to_alice_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, amount);
        assertEq(totalClaimableForAsset, amount);
        assertEq(totalClaimable, amount);
    }

    function test_USTB_requestRedeem_to_alice_multiple() public {

        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint/2;
        uint256 amount2 = amountToMint - amount1;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amountToMint);
        _deal(address(unrealUSTB), address(djUsdMintingContract), amountToMint);

        IDJUSDMinting.Order memory order1 = IDJUSDMinting.Order({
            expiry: block.timestamp + 10,
            nonce: 1,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount1
        });

        IDJUSDMinting.Order memory order2 = IDJUSDMinting.Order({
            expiry: block.timestamp + 10,
            nonce: 2,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount2
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount1 + amount2);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount1 + amount2);

        // ~ Alice executes requestRedeem 1 ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount1);
        djUsdMintingContract.requestRedeem(order1);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), amount2);
        assertEq(unrealUSTB.balanceOf(alice), 0);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
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
        assertEq(unrealUSTB.balanceOf(alice), 0);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1 + amount2);
        assertEq(totalRequestedUSTB, amount1 + amount2);
        assertEq(totalRequested, amount1 + amount2);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1 + amount2);
        assertEq(totalRequestedUSTB, amount1 + amount2);
        assertEq(totalRequested, amount1 + amount2);

        assertEq(claimableForAlice, amount1);
        assertEq(totalClaimableForAsset, amount1);
        assertEq(totalClaimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount1 + amount2);
        assertEq(totalRequestedUSTB, amount1 + amount2);
        assertEq(totalRequested, amount1 + amount2);

        assertEq(claimableForAlice, amount1 + amount2);
        assertEq(totalClaimableForAsset, amount1 + amount2);
        assertEq(totalClaimable, amount1 + amount2);
    }

    function test_USTB_claim_noFuzz() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
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
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        uint256 preBal = unrealUSTB.balanceOf(address(djUsdMintingContract));

        vm.prank(alice);
        djUsdMintingContract.claim(order);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(alice), amount, 1);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), preBal - amount, 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested - djUsdMintingContract.claimed(alice, address(unrealUSTB)), 0);
        assertEq(totalRequestedUSTB - djUsdMintingContract.totalClaimed(address(unrealUSTB)), 0);
        assertEq(totalRequested - djUsdMintingContract.totalClaimed(address(unrealUSTB)), 0);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);
    }

    function test_USTB_claim_early_revert() public {

        // ~ config ~

        uint256 amount = 10 ether;
        
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
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
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDJUSDMinting.NoAssetsClaimable.selector));
        djUsdMintingContract.claim(order);
    }

    function test_USTB_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(djUsdMintingContract), amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        // ~ Pre-state check ~

        assertEq(djUsdToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        // ~ Alice executes requestRedeem ~
        
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();
        
        // ~ Post-state check 1 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, amount);
        assertEq(totalRequestedUSTB, amount);
        assertEq(totalRequested, amount);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
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
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        uint256 preBal = unrealUSTB.balanceOf(address(djUsdMintingContract));

        vm.prank(alice);
        djUsdMintingContract.claim(order);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(alice), amount, 2);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), preBal - amount, 2);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested - djUsdMintingContract.claimed(alice, address(unrealUSTB)), 0);
        assertEq(totalRequestedUSTB - djUsdMintingContract.totalClaimed(address(unrealUSTB)), 0);
        assertEq(totalRequested - djUsdMintingContract.totalClaimed(address(unrealUSTB)), 0);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);
    }

    function test_USTB_mint_after_rebase_fuzzing(uint256 index) public {
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
        _deal(address(unrealUSTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 18,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        uint256 preBal = unrealUSTB.balanceOf(alice);

        // taker
        vm.startPrank(alice);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount, 1);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 3);
    }

    function test_USTB_requestRedeem_after_rebase_noFuzz() public {

        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 1,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // ~ Mint ~

        uint256 preBal = unrealUSTB.balanceOf(alice);

        vm.startPrank(alice);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount, 1);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 1);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on DJUSD ~
        
        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * djUsdToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 2);
        _deal(address(unrealUSTB), address(djUsdMintingContract), newBal);

        newBal = djUsdToken.balanceOf(alice);

        // ~ Alice executes requestRedeem ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 2,
            collateral_asset: address(unrealUSTB),
            collateral_amount: newBal
        });

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, newBal);
        assertEq(totalClaimableForAsset, newBal);
        assertEq(totalClaimable, newBal);
    }

    function test_USTB_requestRedeem_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.0000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 1,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        uint256 preBal = unrealUSTB.balanceOf(alice);

        // mint
        vm.startPrank(alice);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount, 1);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 1);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;
        
        // setRebaseIndex
        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 100);
        uint256 newBal = amount * djUsdToken.rebaseIndex() / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 2);
        _deal(address(unrealUSTB), address(djUsdMintingContract), newBal);

        newBal = djUsdToken.balanceOf(alice);

        // redeem
        order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 2,
            collateral_asset: address(unrealUSTB),
            collateral_amount: newBal
        });

        // taker
        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay() - 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, newBal);
        assertEq(totalClaimableForAsset, newBal);
        assertEq(totalClaimable, newBal);
    }

    function test_USTB_claim_after_rebase_noFuzz() public {

        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), alice, amount);

        IDJUSDMinting.Order memory order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 1,
            collateral_asset: address(unrealUSTB),
            collateral_amount: amount
        });

        address[] memory targets = new address[](1);
        targets[0] = address(djUsdMintingContract);
        uint256[] memory ratios = new uint256[](1);
        ratios[0] = 10_000;

        IDJUSDMinting.Route memory route = IDJUSDMinting.Route({addresses: targets, ratios: ratios});

        // ~ Mint ~

        vm.startPrank(alice);
        unrealUSTB.approve(address(djUsdMintingContract), amount);
        djUsdMintingContract.mint(order, route);
        vm.stopPrank();

        _deal(address(unrealUSTB), alice, 0);

        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(djUsdMintingContract)), amount, 1);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), amount, 1);

        uint256 preTotalSupply = djUsdToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on DJUSD ~
        
        vm.prank(rebaseManager);
        djUsdToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(djUsdToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (preTotalSupply * djUsdToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(djUsdToken.balanceOf(alice), newBal, 2);
        _deal(address(unrealUSTB), address(djUsdMintingContract), newBal);

        newBal = djUsdToken.balanceOf(alice);

        // ~ Alice executes requestRedeem ~

        order = IDJUSDMinting.Order({
            expiry: block.timestamp + 10 minutes,
            nonce: 2,
            collateral_asset: address(unrealUSTB),
            collateral_amount: newBal
        });

        vm.startPrank(alice);
        djUsdToken.approve(address(djUsdMintingContract), newBal);
        djUsdMintingContract.requestRedeem(order);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(djUsdMintingContract)), newBal);

        uint256 requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        uint256 totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        uint256 claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        uint256 totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        uint256 totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested, newBal);
        assertEq(totalRequestedUSTB, newBal);
        assertEq(totalRequested, newBal);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + djUsdMintingContract.claimDelay());

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
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
            collateral_asset: address(unrealUSTB),
            collateral_amount: newBal
        });

        vm.prank(alice);
        djUsdMintingContract.claim(order);

        // ~ Post-state check 2 ~

        assertEq(djUsdToken.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(alice), newBal, 1);

        requested = djUsdMintingContract.accountRequestCheckpointsManualLookup(alice, address(unrealUSTB), uint48(block.timestamp));
        totalRequestedUSTB = djUsdMintingContract.totalRequestCheckpointsForAssetManualLookup(address(unrealUSTB), uint48(block.timestamp));
        totalRequested = djUsdMintingContract.totalRequestCheckpointsManualLookup(uint48(block.timestamp));
        claimableForAlice = djUsdMintingContract.getClaimableForAccount(alice, address(unrealUSTB));
        totalClaimableForAsset = djUsdMintingContract.getTotalClaimableForAsset(address(unrealUSTB));
        totalClaimable = djUsdMintingContract.getTotalClaimable();

        assertEq(requested - djUsdMintingContract.claimed(alice, address(unrealUSTB)), 0);
        assertEq(totalRequestedUSTB - djUsdMintingContract.totalClaimed(address(unrealUSTB)), 0);
        assertEq(totalRequested - djUsdMintingContract.totalClaimed(address(unrealUSTB)), 0);

        assertEq(claimableForAlice, 0);
        assertEq(totalClaimableForAsset, 0);
        assertEq(totalClaimable, 0);
    }
}