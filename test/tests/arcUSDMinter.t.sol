// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// local imports
import {BaseSetup} from "../BaseSetup.sol";
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";
import {MockToken} from "../mock/MockToken.sol";
import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSD} from "../../src/interfaces/IarcUSD.sol";
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {IarcUSDDefinitions} from "../../src/interfaces/IarcUSDDefinitions.sol";
import {CommonErrors} from "../../src/interfaces/CommonErrors.sol";

/**
 * @title arcUSDMinterCoreTest
 * @notice Unit Tests for arcUSDMinter contract interactions
 */
contract arcUSDMinterCoreTest is BaseSetup, CommonErrors {
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();
    }

    function test_init_state() public {
        assertNotEq(arcUSDToken.taxManager(), address(0));

        address[] memory assets = arcMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        assertEq(arcMinter.custodian(), address(custodian));
    }

    function test_arcMinter_initializer() public {
        arcUSDMinter newarcUSDMinter = new arcUSDMinter(address(arcUSDToken));
        ERC1967Proxy newarcUSDMinterProxy = new ERC1967Proxy(
            address(newarcUSDMinter),
            abi.encodeWithSelector(arcUSDMinter.initialize.selector,
                owner,
                admin,
                whitelister,
                5 days
            )
        );
        newarcUSDMinter = arcUSDMinter(payable(address(newarcUSDMinterProxy)));

        assertEq(newarcUSDMinter.owner(), owner);
        assertEq(newarcUSDMinter.admin(), admin);
        assertEq(newarcUSDMinter.whitelister(), whitelister);
        assertEq(newarcUSDMinter.claimDelay(), 5 days);
        assertEq(newarcUSDMinter.latestCoverageRatio(), 1e18);
    }

    function test_arcMinter_isUpgradeable() public {
        arcUSDMinter newImplementation = new arcUSDMinter(address(arcUSDToken));

        bytes32 implementationSlot =
            vm.load(address(arcMinter), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertNotEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));

        vm.prank(owner);
        arcMinter.upgradeToAndCall(address(newImplementation), "");

        implementationSlot =
            vm.load(address(arcMinter), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(implementationSlot, bytes32(abi.encode(address(newImplementation))));
    }

    function test_arcMinter_isUpgradeable_onlyOwner() public {
        arcUSDMinter newImplementation = new arcUSDMinter(address(arcUSDToken));

        vm.prank(minter);
        vm.expectRevert();
        arcMinter.upgradeToAndCall(address(newImplementation), "");

        vm.prank(owner);
        arcMinter.upgradeToAndCall(address(newImplementation), "");
    }

    function test_arcMinter_unsupported_assets_ERC20_revert() public {
        vm.startPrank(owner);
        arcMinter.removeSupportedAsset(address(USTB));
        USTB.mint(_amountToDeposit, bob);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(arcMinter), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        arcMinter.mint(address(USTB), _amountToDeposit, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_arcMinter_unsupported_assets_ETH_revert() public {
        vm.startPrank(owner);
        vm.deal(bob, _amountToDeposit);
        vm.stopPrank();

        // taker
        vm.startPrank(bob);
        USTB.approve(address(arcMinter), _amountToDeposit);
        vm.stopPrank();

        vm.recordLogs();
        vm.expectRevert();
        vm.prank(bob);
        arcMinter.mint(NATIVE_TOKEN, _amountToDeposit, _amountToDeposit);
        vm.getRecordedLogs();
    }

    function test_arcMinter_add_and_remove_supported_asset() public {
        address asset = address(20);
        address oracle = address(21);
        vm.startPrank(owner);
        arcMinter.addSupportedAsset(asset, oracle);
        assertTrue(arcMinter.isSupportedAsset(asset));

        arcMinter.removeSupportedAsset(asset);
        assertFalse(arcMinter.isSupportedAsset(asset));
    }

    function test_arcMinter_cannot_add_asset_already_supported_revert() public {
        address asset = address(20);
        address oracle = address(21);
        vm.startPrank(owner);
        arcMinter.addSupportedAsset(asset, oracle);
        assertTrue(arcMinter.isSupportedAsset(asset));

        vm.expectRevert(abi.encodeWithSelector(AlreadyExists.selector, asset));
        arcMinter.addSupportedAsset(asset, oracle);
    }

    function test_arcMinter_cannot_removeAsset_not_supported_revert() public {
        address asset = address(20);
        assertFalse(arcMinter.isSupportedAsset(asset));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(arcUSDMinter.NotSupportedAsset.selector, asset));
        arcMinter.removeSupportedAsset(asset);
    }

    function test_arcMinter_cannotAdd_addressZero_revert() public {
        vm.prank(owner);
        vm.expectRevert(InvalidZeroAddress.selector);
        arcMinter.addSupportedAsset(address(0), address(1));
    }

    function test_arcMinter_cannotAdd_arcUSD_revert() public {
        vm.prank(owner);
        vm.expectRevert();
        arcMinter.addSupportedAsset(address(arcUSDToken), address(1));
    }

    function test_arcMinter_receive_eth() public {
        assertEq(address(arcMinter).balance, 0);
        vm.deal(owner, 10_000 ether);
        vm.prank(owner);
        (bool success,) = address(arcMinter).call{value: 10_000 ether}("");
        assertFalse(success);
        assertEq(address(arcMinter).balance, 0);
    }

    function test_arcMinter_mint() public {
        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertEq(arcUSDToken.balanceOf(bob), amount);
    }

    function test_arcMinter_mint_tax() public {
        vm.prank(owner);
        arcMinter.updateTax(2); // .2% tax

        uint256 amount = 10 ether;
        deal(address(USTB), bob, amount);
        
        uint256 amountAfterTax = amount - (amount * arcMinter.tax() / 1000);
        assertLt(amountAfterTax, amount);

        // taker
        vm.startPrank(bob);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amountAfterTax);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertEq(arcUSDToken.balanceOf(bob), amountAfterTax);
    }

    function test_arcMinter_mint_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);
        deal(address(USTB), bob, amount);

        assertEq(amount, arcMinter.quoteMint(address(USTB), bob, amount));

        // taker
        vm.startPrank(bob);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertEq(arcUSDToken.balanceOf(bob), amount);
    }

    function test_arcMinter_mint_tax_fuzzing(uint256 amount) public {
        vm.assume(amount > 1000 && amount < _maxMintPerBlock);
        deal(address(USTB), bob, amount);

        vm.prank(owner);
        arcMinter.updateTax(2); // .2% tax
        
        uint256 amountAfterTax = amount - (amount * arcMinter.tax() / 1000);

        assertLt(amountAfterTax, amount);
        assertEq(amountAfterTax, arcMinter.quoteMint(address(USTB), bob, amount));

        // taker
        vm.startPrank(bob);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amountAfterTax);
        vm.stopPrank();

        assertEq(USTB.balanceOf(bob), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertEq(arcUSDToken.balanceOf(bob), amountAfterTax);
    }

    function test_arcMinter_requestTokens_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        assertEq(arcMinter.quoteRedeem(address(USTB), alice, amount), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_arcMinter_requestTokens_tax_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // set tax
        vm.prank(owner);
        arcMinter.updateTax(2); // .2% tax

        uint256 amountAfterTax = amount - (amount * arcMinter.tax() / 1000);

        assertLt(amountAfterTax, amount);
        assertEq(arcMinter.quoteRedeem(address(USTB), alice, amount), amountAfterTax);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amountAfterTax);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amountAfterTax);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amountAfterTax);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amountAfterTax);
        assertEq(claimable, amountAfterTax);
    }

    function test_arcMinter_requestTokens_then_extendClaimTimestamp() public {
        // ~ config ~

        uint256 amount = 10 ether;

        uint256 newDelay = 10 days;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Custodian executes extendClaimTimestamp ~

        vm.prank(admin);
        arcMinter.extendClaimTimestamp(alice, address(USTB), 0, uint48(block.timestamp + newDelay));

        // ~ Warp to original post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to new post-claimDelay and query claimable ~

        vm.warp(block.timestamp + newDelay);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_arcMinter_requestTokens_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        assertEq(arcMinter.quoteRedeem(address(USTB), alice, amount), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_arcMinter_requestTokens_tax_fuzzing(uint256 amount) public {
        vm.assume(amount > 1000 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // set tax
        vm.prank(owner);
        arcMinter.updateTax(2); // .2% tax

        uint256 amountAfterTax = amount - (amount * arcMinter.tax() / 1000);

        assertLt(amountAfterTax, amount);
        assertEq(arcMinter.quoteRedeem(address(USTB), alice, amount), amountAfterTax);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amountAfterTax);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amountAfterTax);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amountAfterTax);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amountAfterTax);
        assertEq(claimable, amountAfterTax);
    }

    function test_arcMinter_requestTokens_multiple() public {
        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint / 2;
        uint256 amount2 = amountToMint - amount1;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amountToMint);
        deal(address(USTB), address(arcMinter), amountToMint);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount1 + amount2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount1 + amount2);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens 1 ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount1);
        arcMinter.requestTokens(address(USTB), amount1);
        vm.stopPrank();

        uint256 request1 = block.timestamp;

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), amount2);
        assertEq(USTB.balanceOf(alice), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].asset, address(USTB));
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1);
        assertEq(claimable, 0);

        // ~ Alice executes requestTokens 2 ~

        vm.warp(block.timestamp + 1);

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount2);
        arcMinter.requestTokens(address(USTB), amount2);
        vm.stopPrank();

        uint256 request2 = block.timestamp;

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].asset, address(USTB));
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);
        assertEq(requests[1].amount, amount2);
        assertEq(requests[1].asset, address(USTB));
        assertEq(requests[1].claimableAfter, request2 + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1 + amount2);
    }

    function test_arcMinter_claim_multiple_assets() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount * 2);
        deal(address(USTB), address(arcMinter), amount);
        deal(address(USDCToken), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount * 2);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);

        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USDCToken), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requestedUSTB = arcMinter.getPendingClaims(address(USTB));
        uint256 requestedUSDC = arcMinter.getPendingClaims(address(USDCToken));

        uint256 claimableUSTB = arcMinter.claimableTokens(alice, address(USTB));
        uint256 claimableUSDC = arcMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requestedUSTB = arcMinter.getPendingClaims(address(USTB));
        requestedUSDC = arcMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = arcMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = arcMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, amount);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, amount);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USTB ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), 0);
        assertEq(USDCToken.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, 0);

        requestedUSTB = arcMinter.getPendingClaims(address(USTB));
        requestedUSDC = arcMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = arcMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = arcMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, amount);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, amount);

        // ~ Alice claims USDC ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USDCToken));

        // ~ Post-state check 3 ~

        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USDCToken.balanceOf(alice), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USDCToken), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimed, amount);

        requestedUSTB = arcMinter.getPendingClaims(address(USTB));
        requestedUSDC = arcMinter.getPendingClaims(address(USDCToken));

        claimableUSTB = arcMinter.claimableTokens(alice, address(USTB));
        claimableUSDC = arcMinter.claimableTokens(alice, address(USDCToken));

        assertEq(requestedUSTB, 0);
        assertEq(requestedUSDC, 0);
        assertEq(claimableUSTB, 0);
        assertEq(claimableUSDC, 0);
    }

    function test_arcMinter_claim_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(arcMinter)), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_arcMinter_claim_early_revert() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Alice claims ~

        // claims with 0 funds to be claimed, revert
        vm.prank(alice);
        vm.expectRevert();
        arcMinter.claimTokens(address(USTB));

        deal(address(USTB), address(arcMinter), amount);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        // claims when it's too early, revert
        assertEq(arcMinter.claimableTokens(alice, address(USTB)), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(arcUSDMinter.NoTokensClaimable.selector));
        arcMinter.claimTokens(address(USTB));
    }

    function test_arcMinter_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(address(arcMinter)), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_arcMinter_mint_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.000000000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        vm.prank(address(arcMinter));
        arcUSDToken.mint(bob, 1 ether);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (((preTotalSupply * 1e18) / arcUSDToken.rebaseIndex()) * index) / 1e18;

        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 100);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // taker
        vm.startPrank(alice);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, 0);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 2);
    }

    function test_arcMinter_requestTokens_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on arcUSD ~

        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * arcUSDToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(arcMinter), newBal);

        assertEq(arcMinter.quoteRedeem(address(USTB), alice, newBal), newBal);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), newBal);
        arcMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), newBal);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_arcMinter_requestTokens_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.0000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // mint
        vm.startPrank(alice);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // setRebaseIndex
        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 100);
        uint256 newBal = amount * arcUSDToken.rebaseIndex() / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(arcMinter), newBal);

        // taker
        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), newBal);
        arcMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), newBal);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_arcMinter_claim_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        deal(address(USTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        USTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(USTB), amount, amount);
        vm.stopPrank();

        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 0);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on arcUSD ~

        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * arcUSDToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), newBal, 0);
        deal(address(USTB), address(arcMinter), newBal);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), newBal);
        arcMinter.requestTokens(address(USTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), newBal);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), newBal);
        assertEq(USTB.balanceOf(address(arcMinter)), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimed, newBal);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_arcMinter_supplyLimit() public {
        arcUSDToken.setSupplyLimit(arcUSDToken.totalSupply());

        vm.startPrank(bob);
        USTB.approve(address(arcMinter), _amountToDeposit);
        vm.expectRevert(LimitExceeded);
        arcMinter.mint(address(USTB), _amountToDeposit, _amountToDeposit);
        vm.stopPrank();
    }

    function test_arcMinter_withdrawFunds() public {
        // ~ Config ~

        uint256 amount = 10 * 1e18;
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertEq(USTB.balanceOf(address(custodian)), 0);

        // ~ Custodian calls withdrawFunds ~

        vm.prank(address(custodian));
        arcMinter.withdrawFunds(address(USTB), amount);

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(address(arcMinter)), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
    }

    function test_arcMinter_withdrawFunds_partial() public {
        // ~ Config ~

        uint256 amount = 10 * 1e18;
        uint256 amountClaim = 5 * 1e18;
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(USTB.balanceOf(address(arcMinter)), amount);
        assertEq(USTB.balanceOf(address(custodian)), 0);

        // ~ Custodian calls withdrawFunds ~

        vm.prank(address(custodian));
        arcMinter.withdrawFunds(address(USTB), amountClaim);

        // ~ Pre-state check 1 ~

        assertEq(USTB.balanceOf(address(arcMinter)), amount - amountClaim);
        assertEq(USTB.balanceOf(address(custodian)), amountClaim);

        // ~ Custodian calls withdrawFunds ~

        vm.prank(address(custodian));
        arcMinter.withdrawFunds(address(USTB), amountClaim);

        // ~ Pre-state check 2 ~

        assertEq(USTB.balanceOf(address(arcMinter)), 0);
        assertEq(USTB.balanceOf(address(custodian)), amount);
    }

    function test_arcMinter_withdrawFunds_restrictions() public {
        uint256 amount = 10 ether;

        // only custodian
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(arcUSDMinter.NotCustodian.selector, bob));
        arcMinter.withdrawFunds(address(USTB), amount);

        vm.prank(address(arcMinter));
        arcUSDToken.mint(bob, amount);
        vm.startPrank(bob);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();
        assertEq(arcMinter.requiredTokens(address(USTB)), amount);

        // required > bal -> No funds to withdraw
        vm.prank(address(custodian));
        vm.expectRevert(abi.encodeWithSelector(arcUSDMinter.NoFundsWithdrawable.selector, amount, 0));
        arcMinter.withdrawFunds(address(USTB), amount);
    }

    function test_arcMinter_setClaimDelay() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.claimDelay(), 5 days);

        // ~ Execute setClaimDelay ~

        vm.prank(owner);
        arcMinter.setClaimDelay(7 days);

        // ~ Post-state check ~

        assertEq(arcMinter.claimDelay(), 7 days);
    }

    function test_arcMinter_updateCustodian() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.custodian(), address(custodian));

        // ~ Execute setClaimDelay ~

        vm.prank(owner);
        arcMinter.updateCustodian(owner);

        // ~ Post-state check ~

        assertEq(arcMinter.custodian(), owner);
    }

    function test_arcMinter_restoreAsset() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.isSupportedAsset(address(USTB)), true);

        address[] memory assets = arcMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        address[] memory allAssets = arcMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));

        // ~ Execute removeSupportedAsset ~

        vm.prank(owner);
        arcMinter.removeSupportedAsset(address(USTB));

        // ~ Post-state check 1 ~

        assertEq(arcMinter.isSupportedAsset(address(USTB)), false);

        assets = arcMinter.getActiveAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(USDCToken));
        assertEq(assets[1], address(USDTToken));

        allAssets = arcMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));

        // ~ Execute restoreAsset ~

        vm.prank(owner);
        arcMinter.restoreAsset(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcMinter.isSupportedAsset(address(USTB)), true);

        assets = arcMinter.getActiveAssets();
        assertEq(assets.length, 3);
        assertEq(assets[0], address(USTB));
        assertEq(assets[1], address(USDCToken));
        assertEq(assets[2], address(USDTToken));

        allAssets = arcMinter.getAllAssets();
        assertEq(allAssets.length, 3);
        assertEq(allAssets[0], address(USTB));
        assertEq(allAssets[1], address(USDCToken));
        assertEq(allAssets[2], address(USDTToken));
    }

    function test_arcMinter_getRedemptionRequests() public {
        // ~ Config ~

        uint256 mintAmount = 1_000 * 1e18;
        uint256 numMints = 5;

        // mint arcUSD to an actor
        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, mintAmount * numMints * 2);

        // ~ Pre-state check ~

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, 0, 10);
        assertEq(requests.length, 0);

        // ~ Execute requests for USTB ~

        for (uint256 i; i < numMints; ++i) {
            // requests for USTB
            vm.startPrank(alice);
            arcUSDToken.approve(address(arcMinter), mintAmount);
            arcMinter.requestTokens(address(USTB), mintAmount);
            vm.stopPrank();
        }

        // ~ Post-state check 1 ~

        requests = arcMinter.getRedemptionRequests(alice, 0, 100);
        assertEq(requests.length, 5);

        // ~ Execute requests for USDC

        for (uint256 i; i < numMints; ++i) {
            // requests for USDC
            vm.startPrank(alice);
            arcUSDToken.approve(address(arcMinter), mintAmount);
            arcMinter.requestTokens(address(USDCToken), mintAmount);
            vm.stopPrank();
        }

        // ~ Post-state check 2 ~

        requests = arcMinter.getRedemptionRequests(alice, 0, 100);
        assertEq(requests.length, 10);

        requests = arcMinter.getRedemptionRequests(alice, 0, 5);
        assertEq(requests.length, 5);
    }

    function test_arcMinter_modifyWhitelist() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.isWhitelisted(bob), true);

        // ~ Execute modifyWhitelist ~

        vm.prank(whitelister);
        arcMinter.modifyWhitelist(bob, false);

        // ~ Post-state check ~

        assertEq(arcMinter.isWhitelisted(bob), false);
    }

    function test_arcMinter_modifyWhitelist_restrictions() public {
        // only whitelister
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(arcUSDMinter.NotWhitelister.selector, bob));
        arcMinter.modifyWhitelist(bob, false);

        // account cannot be address(0)
        vm.prank(whitelister);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        arcMinter.modifyWhitelist(address(0), false);

        // cannot set status to status that's already set
        vm.prank(whitelister);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        arcMinter.modifyWhitelist(bob, true);
    }

    function test_arcMinter_coverageRatio() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.latestCoverageRatio(), 1 * 1e18);

        // ~ Execute setCoverageRatio ~

        skip(10);
        vm.prank(admin);
        arcMinter.setCoverageRatio(.1 * 1e18);

        // ~ Post-state check ~

        assertEq(arcMinter.latestCoverageRatio(), .1 * 1e18);
    }

    function test_arcMinter_coverageRatio_restrictions() public {
        // only admin
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(arcUSDMinter.NotAdmin.selector, bob));
        arcMinter.setCoverageRatio(.1 * 1e18);

        // ratio cannot be greater than 1e18
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueTooHigh.selector, 1 * 1e18 + 1, 1 * 1e18));
        arcMinter.setCoverageRatio(1 * 1e18 + 1);

        // cannot set ratio to already set ratio
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        arcMinter.setCoverageRatio(1 * 1e18);
    }

    function test_arcMinter_updateAdmin() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.admin(), admin);

        // ~ Execute updateAdmin ~

        vm.prank(owner);
        arcMinter.updateAdmin(bob);

        // ~ Post-state check ~

        assertEq(arcMinter.admin(), bob);
    }

    function test_arcMinter_updateAdmin_restrictions() public {
        // only owner
        vm.prank(bob);
        vm.expectRevert();
        arcMinter.updateAdmin(bob);

        // admin cannot be address(0)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        arcMinter.updateAdmin(address(0));

        // cannot set to value already set
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        arcMinter.updateAdmin(admin);
    }

    function test_arcMinter_updateWhitelister() public {
        // ~ Pre-state check ~

        assertEq(arcMinter.whitelister(), whitelister);

        // ~ Execute updateWhitelister ~

        vm.prank(owner);
        arcMinter.updateWhitelister(bob);

        // ~ Post-state check ~

        assertEq(arcMinter.whitelister(), bob);
    }

    function test_arcMinter_updateWhitelister_restrictions() public {
        // only owner
        vm.prank(bob);
        vm.expectRevert();
        arcMinter.updateWhitelister(bob);

        // whitelister cannot be address(0)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.InvalidZeroAddress.selector));
        arcMinter.updateWhitelister(address(0));

        // cannot set to value already set
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CommonErrors.ValueUnchanged.selector));
        arcMinter.updateWhitelister(whitelister);
    }

    function test_arcMinter_claimable_coverageRatioSub1() public {
        // ~ config ~

        uint256 amount = 10 ether;
        uint256 ratio = .9 ether; // 90%

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // Warp to post-claimDelay and query claimable
        vm.warp(block.timestamp + arcMinter.claimDelay());
        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));
        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        arcMinter.setCoverageRatio(ratio);

        // ~ Post-state check ~

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));
        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amount * ratio / 1e18);
    }

    function test_arcMinter_claimTokens_coverageRatioSub1() public {
        // ~ config ~

        uint256 amount = 10 ether;
        uint256 ratio = .9 ether; // 90%

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        arcMinter.setCoverageRatio(ratio);

        uint256 amountAfterRatio = amount * ratio / 1e18;

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amountAfterRatio);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(arcMinter)), amount - amountAfterRatio);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_arcMinter_claimTokens_coverageRatioSub1_fuzzing(uint256 ratio) public {
        ratio = bound(ratio, .01 ether, .9999 ether); // 1% -> 99.99%

        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        deal(address(USTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        arcMinter.setCoverageRatio(ratio);

        uint256 amountAfterRatio = amount * ratio / 1e18;

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amountAfterRatio);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(arcMinter)), amount - amountAfterRatio);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_arcMinter_claimTokens_coverageRatioSub1_multiple() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount*2);
        deal(address(USTB), address(arcMinter), amount*2);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount*2);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount*2);

        arcUSDMinter.RedemptionRequest[] memory requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(address(arcMinter)), amount*2);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(USTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        arcMinter.setCoverageRatio(.9 ether);
        assertEq(arcMinter.latestCoverageRatio(), .9 ether);

        uint256 ratio = arcMinter.latestCoverageRatio();
        uint256 amountAfterRatio = amount * ratio / 1e18;

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertLt(claimable, amount);
        assertEq(claimable, amountAfterRatio);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(arcMinter)), amount*2 - amountAfterRatio);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);

        // ~ alice requests another claim ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(USTB), amount);
        vm.stopPrank();

        // ~ Post-state check 3 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amountAfterRatio);
        assertEq(USTB.balanceOf(address(arcMinter)), amount*2 - amountAfterRatio);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);
        assertEq(requests[1].amount, amount);
        assertEq(requests[1].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Update coverage ratio ~

        vm.prank(admin);
        arcMinter.setCoverageRatio(1 ether);
        assertEq(arcMinter.latestCoverageRatio(), 1 ether);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(USTB));

        // ~ Post-state check 4 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(USTB.balanceOf(alice), amount + amountAfterRatio);
        assertEq(USTB.balanceOf(address(arcMinter)), amount - amountAfterRatio);

        requests = arcMinter.getRedemptionRequests(alice, address(USTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount);
        assertLt(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount * ratio / 1e18);
        assertEq(requests[1].amount, amount);
        assertEq(requests[1].claimableAfter, block.timestamp);
        assertEq(requests[1].claimed, amount);

        requested = arcMinter.getPendingClaims(address(USTB));
        claimable = arcMinter.claimableTokens(alice, address(USTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_arcMinter_quoteMint() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 newPrice = 1.2 * 1e18;

        assertEq(arcMinter.quoteMint(address(USTB), bob, amountIn), amountIn);
        assertEq(USTBOracle.latestPrice(), 1 * 1e18);

        _changeOraclePrice(address(USTBOracle), newPrice);

        assertEq(arcMinter.quoteMint(address(USTB), bob, amountIn), amountIn * newPrice / 1e18);
        assertEq(USTBOracle.latestPrice(), 1.2 * 1e18);
    }

    function test_arcMinter_quoteRedeem() public {
        uint256 amountIn = 1_000 * 1e18;
        uint256 newPrice = 1.2 * 1e18;

        assertEq(arcMinter.quoteRedeem(address(USTB), bob, amountIn), amountIn);
        assertEq(USTBOracle.latestPrice(), 1 * 1e18);

        _changeOraclePrice(address(USTBOracle), newPrice);

        assertEq(arcMinter.quoteRedeem(address(USTB), bob, amountIn), amountIn * 1e18 / newPrice);
        assertEq(USTBOracle.latestPrice(), 1.2 * 1e18);
    }
}
