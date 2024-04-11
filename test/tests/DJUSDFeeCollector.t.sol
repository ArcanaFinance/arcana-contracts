// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {DJUSDFeeCollector} from "../../src/DJUSDFeeCollector.sol";

/**
 * @title DJUSDFeeCollectorTest
 * @notice Unit Tests for DJUSDFeeCollector contract interactions
 */
contract DJUSDFeeCollectorTest is BaseSetup {

    address public constant REVENUE_DISTRIBUTOR = address(bytes20(bytes("REVENUE_DISTRIBUTOR")));
    address public constant DJINN_ESCROW = address(bytes20(bytes("DJINN_ESCROW")));

    function setUp() public override {
        super.setUp();

        address[] memory distributors = new address[](2);
        distributors[0] = REVENUE_DISTRIBUTOR;
        distributors[1] = DJINN_ESCROW;

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        vm.prank(owner);
        feeCollector.updateRewardDistribution(distributors, ratios);
    }

    function test_feeColector_init_state() public {
        assertEq(feeCollector.DJUSD(), address(djUsdToken));
        assertEq(feeCollector.distributors(0), REVENUE_DISTRIBUTOR);
        assertEq(feeCollector.distributors(1), DJINN_ESCROW);
    }

    function test_feeCollector_distributeDJUSD() public {
        // ~ Config ~

        uint256 amount = 1 ether;
        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(address(feeCollector), amount);

        // ~ Pre-State check ~

        assertEq(djUsdToken.balanceOf(address(feeCollector)), amount);
        assertEq(djUsdToken.balanceOf(REVENUE_DISTRIBUTOR), 0);
        assertEq(djUsdToken.balanceOf(DJINN_ESCROW), 0);

        // ~ Execute distributeDJUSD ~

        feeCollector.distributeDJUSD();

        // ~ Pre-State check ~

        assertEq(djUsdToken.balanceOf(address(feeCollector)), 0);
        assertEq(djUsdToken.balanceOf(REVENUE_DISTRIBUTOR), amount/2);
        assertEq(djUsdToken.balanceOf(DJINN_ESCROW), amount/2);
    }

    function test_feeCollector_distributeDJUSD_fuzzing(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        vm.prank(address(djUsdMintingContract));
        djUsdToken.mint(address(feeCollector), amount);

        // ~ Pre-State check ~

        assertEq(djUsdToken.balanceOf(address(feeCollector)), amount);
        assertEq(djUsdToken.balanceOf(REVENUE_DISTRIBUTOR), 0);
        assertEq(djUsdToken.balanceOf(DJINN_ESCROW), 0);

        // ~ Execute distributeDJUSD ~

        feeCollector.distributeDJUSD();

        // ~ Pre-State check ~

        assertApproxEqAbs(djUsdToken.balanceOf(address(feeCollector)), 0, 1);
        assertEq(djUsdToken.balanceOf(REVENUE_DISTRIBUTOR), amount/2);
        assertEq(djUsdToken.balanceOf(DJINN_ESCROW), amount/2);
    }
}
