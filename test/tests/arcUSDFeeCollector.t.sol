// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* solhint-disable func-name-mixedcase  */

// oz imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// local files
import {BaseSetup} from "../BaseSetup.sol";
import {arcUSDFeeCollector} from "../../src/arcUSDFeeCollector.sol";

/**
 * @title arcUSDFeeCollectorTest
 * @notice Unit Tests for arcUSDFeeCollector contract interactions
 */
contract arcUSDFeeCollectorTest is BaseSetup {
    address public constant REVENUE_DISTRIBUTOR = address(bytes20(bytes("REVENUE_DISTRIBUTOR")));
    address public constant ARCANA_ESCROW = address(bytes20(bytes("ARCANA_ESCROW")));

    function setUp() public override {
        super.setUp();

        address[] memory distributors = new address[](2);
        distributors[0] = REVENUE_DISTRIBUTOR;
        distributors[1] = ARCANA_ESCROW;

        uint256[] memory ratios = new uint256[](2);
        ratios[0] = 1;
        ratios[1] = 1;

        vm.prank(owner);
        feeCollector.updateRewardDistribution(distributors, ratios);
    }

    function test_feeColector_init_state() public {
        assertEq(feeCollector.arcUSD(), address(arcUSDToken));
        assertEq(feeCollector.distributors(0), REVENUE_DISTRIBUTOR);
        assertEq(feeCollector.distributors(1), ARCANA_ESCROW);
    }

    function test_feeCollector_distributeArcUSD() public {
        // ~ Config ~

        uint256 amount = 1 ether;
        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(feeCollector), amount);

        // ~ Pre-State check ~

        assertEq(arcUSDToken.balanceOf(address(feeCollector)), amount);
        assertEq(arcUSDToken.balanceOf(REVENUE_DISTRIBUTOR), 0);
        assertEq(arcUSDToken.balanceOf(ARCANA_ESCROW), 0);

        // ~ Execute distributeArcUSD ~

        feeCollector.distributeArcUSD();

        // ~ Pre-State check ~

        assertEq(arcUSDToken.balanceOf(address(feeCollector)), 0);
        assertEq(arcUSDToken.balanceOf(REVENUE_DISTRIBUTOR), amount / 2);
        assertEq(arcUSDToken.balanceOf(ARCANA_ESCROW), amount / 2);
    }

    function test_feeCollector_distributearcUSD_fuzzing(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);

        // ~ Config ~

        vm.prank(address(arcMinter));
        arcUSDToken.mint(address(feeCollector), amount);

        // ~ Pre-State check ~

        assertEq(arcUSDToken.balanceOf(address(feeCollector)), amount);
        assertEq(arcUSDToken.balanceOf(REVENUE_DISTRIBUTOR), 0);
        assertEq(arcUSDToken.balanceOf(ARCANA_ESCROW), 0);

        // ~ Execute distributeArcUSD ~

        feeCollector.distributeArcUSD();

        // ~ Pre-State check ~

        assertApproxEqAbs(arcUSDToken.balanceOf(address(feeCollector)), 0, 1);
        assertEq(arcUSDToken.balanceOf(REVENUE_DISTRIBUTOR), amount / 2);
        assertEq(arcUSDToken.balanceOf(ARCANA_ESCROW), amount / 2);
    }
}
