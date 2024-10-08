// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

import {Test} from "forge-std/Test.sol";

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {arcUSDMinter} from "../../src/arcUSDMinter.sol";
import {CustodianManager} from "../../src/CustodianManager.sol";
import {arcUSD} from "../../src/arcUSD.sol";
import {IarcUSDDefinitions} from "../../src/interfaces/IarcUSDDefinitions.sol";
import {IRebaseToken} from "../../src/interfaces/IRebaseToken.sol";

// helpers
import "../utils/Constants.sol";
import {MockOracle} from "../mock/MockOracle.sol";

/**
 * @title arcUSDMinterUSDCIntegrationTest
 * @notice Unit Tests for arcUSDMinter contract interactions
 */
contract arcUSDMinterUSDCIntegrationTest is Test {
    string public REAL_RPC_URL = vm.envString("REAL_RPC_URL");

    arcUSD internal arcUSDToken;
    arcUSDMinter internal arcMinter;
    CustodianManager internal custodianManager;

    IERC20 public reUSDC = IERC20(REAL_USDC);

    address public constant OWNER = 0x946C569791De3283f33372731d77555083c329da;
    address public constant REBASE_MANAGER = 0x1FB57aF994a03c49f9B1b7Eef938519463CdF996;
    address public constant CUSTODIAN = 0x499D011d7F13c707EebEe5B677A772d853723C0F;
    address public constant ALICE = address(bytes20(bytes("Alice")));
    address public constant BOB = address(bytes20(bytes("Bob")));

    function setUp() public {
        vm.createSelectFork(REAL_RPC_URL);

        arcUSDToken = arcUSD(0xAEC9e50e3397f9ddC635C6c429C8C7eca418a143);
        arcMinter = arcUSDMinter(0x6C2c653BCEB606bE8E7e92D008c62D0e05a83fd9);
        custodianManager = CustodianManager(0xD0b3DfCB4383b10d964A4E0cb1a0Cea19C9F89AC);

        // Deploy oracle for reUSDC
        MockOracle USDCOracle = new MockOracle(
            address(reUSDC),
            1e18,
            18
        );

        vm.startPrank(OWNER);
        arcMinter.addSupportedAsset(address(reUSDC), address(USDCOracle));
        arcMinter.modifyWhitelist(ALICE, true);
        arcMinter.modifyWhitelist(BOB, true);
        vm.stopPrank();

        _createLabels();
    }


    // -------
    // Utility
    // -------

    function _createLabels() internal {
        vm.label(OWNER, "OWNER");
        vm.label(CUSTODIAN, "CUSTODIAN");
        vm.label(BOB, "BOB");
        vm.label(ALICE, "ALICE");
        vm.label(address(reUSDC), "reUSDC");
        vm.label(address(arcUSDToken), "arcUSD");
        vm.label(address(arcMinter), "arcUSDMinter");
    }


    // ----------
    // Unit Tests
    // ----------

    function test_USDC_mint_static() public {
        uint256 amount = 10 * 1e6;
        deal(address(reUSDC), BOB, amount);

        uint256 preBal = reUSDC.balanceOf(BOB);
        uint256 quoted = arcMinter.quoteMint(address(reUSDC), BOB, amount);

        // taker
        vm.startPrank(BOB);
        reUSDC.approve(address(arcMinter), amount);
        arcMinter.mint(address(reUSDC), amount, amount - 1);
        vm.stopPrank();

        assertEq(reUSDC.balanceOf(BOB), preBal - amount);
        assertApproxEqAbs(reUSDC.balanceOf(address(arcMinter)), amount, 1);
        assertApproxEqAbs(arcUSDToken.balanceOf(BOB), quoted, 1);
    }

    function test_USDC_mint_fuzzing(uint256 amount) public {
        vm.assume(amount > 0.000000000001e18 && amount < 100_000 * 1e6);
        deal(address(reUSDC), BOB, amount);

        uint256 preBal = reUSDC.balanceOf(BOB);
        uint256 deviation = amount * 1 / 100; // 1% deviation
        uint256 quoted = arcMinter.quoteMint(address(reUSDC), BOB, amount);

        // taker
        vm.startPrank(BOB);
        reUSDC.approve(address(arcMinter), amount);
        arcMinter.mint(address(reUSDC), amount, amount - deviation);
        vm.stopPrank();

        assertApproxEqAbs(reUSDC.balanceOf(BOB), preBal - amount, 2);
        assertApproxEqAbs(reUSDC.balanceOf(address(arcMinter)), amount, 2);
        assertApproxEqAbs(arcUSDToken.balanceOf(BOB), quoted, 2);
    }

    function test_USDC_requestTokens_to_alice_noFuzz() public {
        // ~ config ~

        uint256 amountArc = 10 * 1e18; // amount of arcUSD -> 18 decimals
        uint256 amountToRedeem = 10 * 1e6; // amount of USDC being claimed -> 6 decimals

        vm.prank(address(arcMinter));
        arcUSDToken.mint(ALICE, amountArc);
        deal(address(reUSDC), address(arcMinter), amountToRedeem);

        // ~ Pre-state check ~

        assertApproxEqAbs(arcUSDToken.balanceOf(ALICE), amountArc, 1);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountToRedeem);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 0);

        uint256 amountIn = arcUSDToken.balanceOf(ALICE);
        uint256 quoteOut = arcMinter.quoteRedeem(address(reUSDC), ALICE, amountIn);

        // ~ Alice executes requestTokens ~

        vm.startPrank(ALICE);
        arcUSDToken.approve(address(arcMinter), amountIn);
        arcMinter.requestTokens(address(reUSDC), amountIn);
        vm.stopPrank();

        // ~ Post-state check ~

        requests = arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, quoteOut);
        assertEq(requests[0].claimableAfter, block.timestamp + 7 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(reUSDC));
        uint256 claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, quoteOut);
    }

    function test_USDC_requestTokens_to_alice_fuzzing(uint256 amountToRedeem) public {
        vm.assume(amountToRedeem > 0.000000000001e18 && amountToRedeem < 100_000 * 1e6);

        uint256 amountArc = amountToRedeem * 1e12; // amount of arcUSD -> 18 decimals
        //uint256 amountToRedeem = 10 * 1e6; // amount of USDC being claimed -> 6 decimals

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(ALICE, amountArc);
        deal(address(reUSDC), address(arcMinter), amountToRedeem);

        // ~ Pre-state check ~

        assertApproxEqAbs(arcUSDToken.balanceOf(ALICE), amountArc, 2);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountToRedeem);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 0);

        uint256 amountIn = arcUSDToken.balanceOf(ALICE);
        uint256 quoteOut = arcMinter.quoteRedeem(address(reUSDC), ALICE, amountIn);

        // ~ Alice executes requestTokens ~

        vm.startPrank(ALICE);
        arcUSDToken.approve(address(arcMinter), amountIn);
        arcMinter.requestTokens(address(reUSDC), amountIn);
        vm.stopPrank();

        // ~ Post-state check ~

        assertEq(arcUSDToken.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountToRedeem);

        requests = arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, quoteOut);
        assertEq(requests[0].claimableAfter, block.timestamp + 7 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(reUSDC));
        uint256 claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, 0);

        // ~ Warp to claimDelay-1 ~

        vm.warp(block.timestamp + arcMinter.claimDelay() - 1);

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, quoteOut);
    }

    function test_USDC_claim_noFuzz() public {
        // ~ config ~

        uint256 amountArc = 10 * 1e18; // amount of arcUSD -> 18 decimals
        uint256 amountToClaim = 10 * 1e6; // amount of USDC being claimed -> 6 decimals

        vm.prank(address(arcMinter));
        arcUSDToken.mint(ALICE, amountArc);
        deal(address(reUSDC), address(arcMinter), amountToClaim);

        // ~ Pre-state check ~

        assertApproxEqAbs(arcUSDToken.balanceOf(ALICE), amountArc, 2);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountToClaim);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 0);

        uint256 amountIn = arcUSDToken.balanceOf(ALICE);
        uint256 quoteOut = arcMinter.quoteRedeem(address(reUSDC), ALICE, amountIn);

        // ~ Alice executes requestTokens ~

        vm.startPrank(ALICE);
        arcUSDToken.approve(address(arcMinter), amountIn);
        arcMinter.requestTokens(address(reUSDC), amountIn);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        assertEq(arcUSDToken.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountToClaim);

        requests = arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, quoteOut);
        assertEq(requests[0].claimableAfter, block.timestamp + 7 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(reUSDC));
        uint256 claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, quoteOut);

        // ~ Alice claims ~

        uint256 preBal = reUSDC.balanceOf(address(arcMinter));

        vm.prank(ALICE);
        arcMinter.claimTokens(address(reUSDC));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(ALICE), 0);
        assertApproxEqAbs(reUSDC.balanceOf(ALICE), quoteOut, 1);
        assertApproxEqAbs(reUSDC.balanceOf(address(arcMinter)), preBal - quoteOut, 1);

        requests = arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, quoteOut);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, quoteOut);

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_USDC_claim_fuzzing(uint256 amountIn) public {
        vm.assume(amountIn > 0.000000000001e18 && amountIn < 100_000 * 1e6);
        uint256 amount = arcMinter.quoteMint(address(reUSDC), ALICE, amountIn);

        // ~ config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(ALICE, amount);
        deal(address(reUSDC), address(arcMinter), amountIn);

        // ~ Pre-state check ~

        emit log_named_uint("arcUSD Balance", arcUSDToken.balanceOf(ALICE));
        emit log_named_uint("reUSDC Amount", amountIn);

        assertApproxEqAbs(arcUSDToken.balanceOf(ALICE), amount, 2);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountIn);

        amount = arcUSDToken.balanceOf(ALICE);
        uint256 quoteOut = arcMinter.quoteRedeem(address(reUSDC), ALICE, amount);

        emit log_named_uint("Redeem Quote", quoteOut);
        emit log_named_uint("Amount arcUSD for redeem", amount);

        // ~ Alice executes requestTokens ~

        vm.startPrank(ALICE);
        arcUSDToken.approve(address(arcMinter), amount);
        arcMinter.requestTokens(address(reUSDC), amount);
        vm.stopPrank();

        // ~ Post-state check 1 ~

        emit log_named_uint("Quoted reUSDC Amount", quoteOut);
        emit log_named_uint("Amount arcUSD Burned", amount);

        assertEq(arcUSDToken.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(ALICE), 0);
        assertEq(reUSDC.balanceOf(address(arcMinter)), amountIn);

        arcUSDMinter.RedemptionRequest[] memory requests =
            arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, quoteOut);
        assertEq(requests[0].claimableAfter, block.timestamp + 7 days);
        assertEq(requests[0].claimed, 0);

        uint256 requested = arcMinter.getPendingClaims(address(reUSDC));
        uint256 claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, 0);

        // ~ Warp to post-claimDelay and query claimable ~

        vm.warp(block.timestamp + arcMinter.claimDelay());

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, quoteOut);
        assertEq(claimable, quoteOut);

        // ~ Alice claims ~

        uint256 preBal = reUSDC.balanceOf(address(arcMinter));

        vm.prank(ALICE);
        arcMinter.claimTokens(address(reUSDC));

        // ~ Post-state check 2 ~

        assertEq(arcUSDToken.balanceOf(ALICE), 0);
        assertApproxEqAbs(reUSDC.balanceOf(ALICE), quoteOut, 2);
        assertApproxEqAbs(reUSDC.balanceOf(address(arcMinter)), preBal - quoteOut, 2);

        requests = arcMinter.getRedemptionRequests(ALICE, address(reUSDC), 0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0].amount, quoteOut);
        assertEq(requests[0].claimableAfter, block.timestamp);
        assertEq(requests[0].claimed, quoteOut);

        requested = arcMinter.getPendingClaims(address(reUSDC));
        claimable = arcMinter.claimableTokens(ALICE, address(reUSDC));

        assertEq(requested, 0);
        assertEq(claimable, 0);
    }

    function test_USDC_custodianManager_withdrawable() public {

        // ~ config ~

        uint256 amount = 10 * 1e6;

        vm.prank(address(arcMinter));
        arcUSDToken.mint(ALICE, amount * 1e12); 
        deal(address(reUSDC), address(arcMinter), amount);

        // ~ State check ~

        assertEq(reUSDC.balanceOf(address(arcMinter)), amount);

        uint256 bal = arcUSDToken.balanceOf(ALICE);
        assertApproxEqAbs(bal, amount * 1e12, 1);

        assertEq(custodianManager.withdrawable(address(reUSDC)), amount);

        // ~ Perform Redemption Request ~

        vm.startPrank(ALICE);
        arcUSDToken.approve(address(arcMinter), bal/2);
        arcMinter.requestTokens(address(reUSDC), bal/2);
        vm.stopPrank();

        // ~ State check ~

        assertApproxEqAbs(custodianManager.withdrawable(address(reUSDC)), amount/2, 10000); // diff of .01 reUSDC
        assertEq(amount, arcMinter.getPendingClaims(address(reUSDC)) + custodianManager.withdrawable(address(reUSDC)));
    }

    function test_USDC_custodianManager_withdrawFunds() public {
        // ~ config ~

        uint256 amount = 10 * 1e6;
        deal(address(reUSDC), address(arcMinter), amount);

        // ~ State check ~

        assertEq(reUSDC.balanceOf(address(arcMinter)), amount);
        assertEq(custodianManager.withdrawable(address(reUSDC)), amount);

        uint256 preBal = reUSDC.balanceOf(address(CUSTODIAN));

        // ~ Custodian executes a withdrawal

        vm.prank(OWNER);
        custodianManager.withdrawFunds(address(reUSDC), 0);

        // ~ State check ~

        assertEq(reUSDC.balanceOf(address(arcMinter)), 0);
        assertEq(custodianManager.withdrawable(address(reUSDC)), 0);

        assertEq(reUSDC.balanceOf(address(CUSTODIAN)), preBal + amount);
    }
}
