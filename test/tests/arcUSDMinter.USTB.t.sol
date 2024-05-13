// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";
import {arcUSD} from "../../src/arcUSD.sol";
import {arcUSDTaxManager} from "../../src/arcUSDTaxManager.sol";
import {IarcUSDDefinitions} from "../../src/interfaces/IarcUSDDefinitions.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";

// helpers
import "../utils/Constants.sol";

/**
 * @title arcUSDMinterUSTBIntegrationTest
 * @notice Unit Tests for arcUSDMinter contract interactions
 */
contract arcUSDMinterUSTBIntegrationTest is BaseSetup {
    string public UNREAL_RPC_URL = vm.envString("UNREAL_RPC_URL");
    IERC20 public unrealUSTB = IERC20(UNREAL_USTB);

    function setUp() public override {
        vm.createSelectFork(UNREAL_RPC_URL);
        super.setUp();

        // remove unrealUSTB from supported assets and

        vm.startPrank(owner);
        arcMinter.removeSupportedAsset(address(USTB));
        arcMinter.removeSupportedAsset(address(USDCToken));
        arcMinter.removeSupportedAsset(address(USDTToken));

        arcMinter.addSupportedAsset(address(unrealUSTB), address(USTBOracle));
        vm.stopPrank();
    }

    /// @dev local deal to take into account unrealUSTB's unique storage layout
    function _deal(address token, address give, uint256 amount) internal {
        // deal doesn't work with unrealUSTB since the storage layout is different
        if (token == address(unrealUSTB)) {
            // if address is opted out, update normal balance (basket is opted out of rebasing)
            if (give == address(arcMinter)) {
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
        assertNotEq(arcUSDToken.taxManager(), address(0));

        address[] memory assets = arcMinter.getActiveAssets();
        assertEq(assets.length, 1);
        assertEq(assets[0], address(unrealUSTB));

        assertEq(arcMinter.custodian(), address(custodian));
    }

    function test_USTB_mint() public {
        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), bob, amount);

        uint256 preBal = unrealUSTB.balanceOf(bob);
        uint256 quoted = arcMinter.quoteMint(address(unrealUSTB), bob, amount);

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - 1);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(bob), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(bob), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(bob), quoted, 1);
    }

    function test_USTB_mint_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);
        _deal(address(unrealUSTB), bob, amount);

        uint256 preBal = unrealUSTB.balanceOf(bob);
        uint256 deviation = amount * 1 / 100; // 1% deviation
        uint256 quoted = arcMinter.quoteMint(address(unrealUSTB), bob, amount);

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - deviation);
        vm.stopPrank();

        assertApproxEqAbs(unrealUSTB.balanceOf(bob), preBal - amount, 2);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 2);
        assertApproxEqAbs(arcUSDToken.balanceOf(bob), amount, 2);
        assertApproxEqAbs(arcUSDToken.balanceOf(bob), quoted, 2);
    }

    function test_USTB_mint_optedOut_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);
        _deal(address(unrealUSTB), bob, amount);

        vm.prank(bob);
        IRebaseToken(address(unrealUSTB)).disableRebase(bob, true);

        uint256 preBal = unrealUSTB.balanceOf(bob);
        uint256 deviation = amount * 1 / 100; // 1% deviation
        uint256 quoted = arcMinter.quoteMint(address(unrealUSTB), bob, amount);

        // taker
        vm.startPrank(bob);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - deviation);
        vm.stopPrank();

        assertApproxEqAbs(unrealUSTB.balanceOf(bob), preBal - amount, 2);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 2);
        assertApproxEqAbs(arcUSDToken.balanceOf(bob), amount, 2);
        assertApproxEqAbs(arcUSDToken.balanceOf(bob), quoted, 2);
    }

    function test_USTB_requestTokens_to_alice_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(unrealUSTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_USTB_requestTokens_to_alice_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(unrealUSTB), amount);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);
    }

    function test_USTB_requestTokens_to_alice_multiple() public {
        // ~ config ~

        uint256 amountToMint = 10 ether;

        uint256 amount1 = amountToMint / 2;
        uint256 amount2 = amountToMint - amount1;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amountToMint);
        _deal(address(unrealUSTB), address(arcMinter), amountToMint);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount1 + amount2);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount1 + amount2);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens 1 ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount1);
        arcMinter.requestTokens(address(unrealUSTB), amount1);
        vm.stopPrank();

        uint256 request1 = block.timestamp;

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), amount2);
        assertEq(unrealUSTB.balanceOf(alice), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount1);
        assertEq(claimable, 0);

        // ~ Alice executes requestTokens 2 ~

        vm.warp(block.timestamp + 1);

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount2);
        arcMinter.requestTokens(address(unrealUSTB), amount2);
        vm.stopPrank();

        uint256 request2 = block.timestamp;

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 2);
        assertEq(requests[0].amount, amount1);
        assertEq(requests[0].claimableAfter, request1 + 5 days);
        assertEq(requests[0].claimed, 0);
        assertEq(requests[1].amount, amount2);
        assertEq(requests[1].claimableAfter, request2 + 5 days);
        assertEq(requests[1].claimed, 0);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount1 + amount2);
        assertEq(claimable, amount1 + amount2);
    }

    function test_USTB_claim_noFuzz() public {
        // ~ config ~

        uint256 amount = 10 ether;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 0);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(unrealUSTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        uint256 preBal = unrealUSTB.balanceOf(address(arcMinter));

        vm.prank(alice);
        arcMinter.claimTokens(address(unrealUSTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(alice), amount, 1);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), preBal - amount, 1);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_USTB_claim_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < _maxMintPerBlock);

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(alice, amount);
        _deal(address(unrealUSTB), address(arcMinter), amount);

        // ~ Pre-state check ~

        assertEq(arcUSDToken.balanceOf(alice), amount);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(unrealUSTB), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), amount);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, amount);
        assertEq(claimable, amount);

        // ~ Alice claims ~

        uint256 preBal = unrealUSTB.balanceOf(address(arcMinter));

        vm.prank(alice);
        arcMinter.claimTokens(address(unrealUSTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(alice), amount, 2);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), preBal - amount, 2);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, amount);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, amount);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_USTB_mint_after_rebase_fuzzing(uint256 index) public {
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
        _deal(address(unrealUSTB), alice, amount);

        uint256 preBal = unrealUSTB.balanceOf(alice);

        uint256 deviation = amount * 1 / 100; // 1% deviation

        // taker
        vm.startPrank(alice);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - deviation);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 3);
    }

    function test_USTB_requestTokens_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), alice, amount);

        // ~ Mint ~

        uint256 preBal = unrealUSTB.balanceOf(alice);

        vm.startPrank(alice);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - 1);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 1);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on arcUSD ~

        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (amount * arcUSDToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), newBal, 2);
        _deal(address(unrealUSTB), address(arcMinter), newBal);

        newBal = arcUSDToken.balanceOf(alice);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), newBal);
        arcMinter.requestTokens(address(unrealUSTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_USTB_requestTokens_after_rebase_fuzzing(uint256 index) public {
        index = bound(index, 1.0000000001e18, 2e18);
        vm.assume(index > 1e18 && index < 2e18);

        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), alice, amount);

        uint256 preBal = unrealUSTB.balanceOf(alice);

        // mint
        vm.startPrank(alice);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - 1);
        vm.stopPrank();

        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 1);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // setRebaseIndex
        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 100);
        uint256 newBal = amount * arcUSDToken.rebaseIndex() / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), newBal, 2);
        _deal(address(unrealUSTB), address(arcMinter), newBal);

        newBal = arcUSDToken.balanceOf(alice);

        // taker
        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), newBal);
        arcMinter.requestTokens(address(unrealUSTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), preBal - amount);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);
    }

    function test_USTB_claim_after_rebase_noFuzz() public {
        // ~ Config ~

        uint256 index = 1.5 ether;
        uint256 amount = 10 ether;
        _deal(address(unrealUSTB), alice, amount);

        // ~ Mint ~

        vm.startPrank(alice);
        unrealUSTB.approve(address(arcMinter), amount);
        arcMinter.mint(address(unrealUSTB), amount, amount - 1);
        vm.stopPrank();

        _deal(address(unrealUSTB), alice, 0);

        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), amount, 1);

        uint256 preTotalSupply = arcUSDToken.totalSupply();
        uint256 foreshadowTS = (preTotalSupply * index) / 1e18;

        // ~ update rebaseIndex on arcUSD ~

        vm.prank(rebaseManager);
        arcUSDToken.setRebaseIndex(index, 1);

        assertApproxEqAbs(arcUSDToken.totalSupply(), foreshadowTS, 5);
        uint256 newBal = (preTotalSupply * arcUSDToken.rebaseIndex()) / 1e18;
        assertGt(newBal, amount);
        assertApproxEqAbs(arcUSDToken.balanceOf(alice), newBal, 2);
        _deal(address(unrealUSTB), address(arcMinter), newBal);

        newBal = arcUSDToken.balanceOf(alice);

        // ~ Alice executes requestTokens ~

        vm.startPrank(alice);
        arcUSDToken.approve(address(arcMinter), newBal);
        arcMinter.requestTokens(address(unrealUSTB), newBal);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(alice), 0);
        assertEq(unrealUSTB.balanceOf(address(arcMinter)), newBal);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimableAfter, block.timestamp + 5 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(unrealUSTB));
        uint256 claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, newBal);
        assertEq(claimable, newBal);

        // ~ Alice claims ~

        vm.prank(alice);
        arcMinter.claimTokens(address(unrealUSTB));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(alice), 0);
        assertApproxEqAbs(unrealUSTB.balanceOf(alice), newBal, 1);

        requests = arcMinter.getRedemptionRequests(alice, address(unrealUSTB), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, newBal);
        assertEq(requests[0].claimed, newBal);

        requested = arcMinter.getPendingClaims(address(unrealUSTB));
        claimable = arcMinter.claimableTokens(alice, address(unrealUSTB));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }
}
