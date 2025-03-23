// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AutoRebalancingHook} from "../src/AutoRebalancingHook.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {console} from "forge-std/console.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

contract AutoRebalancingHookIntegrationTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    AutoRebalancingHook hook;
    Currency token0;
    Currency token1;
    PoolKey poolKey;
    address user1;
    address user2;

    function setUp() public {
        console.log("=== Setting up integration test ===");

        // Create test users
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy v4-core contracts
        deployFreshManagerAndRouters();
        console.log("Deployed fresh manager and routers");

        // Deploy mock tokens
        (token0, token1) = deployMintAndApprove2Currencies();
        console.log("Deployed mock tokens");
        console.log("Token0:", address(Currency.unwrap(token0)));
        console.log("Token1:", address(Currency.unwrap(token1)));

        // Define hook permissions
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        // Compute the hook address using HookMiner
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(AutoRebalancingHook).creationCode,
            abi.encode(address(manager))
        );

        // Deploy the hook with CREATE2 to ensure it's at the correct address
        hook = new AutoRebalancingHook{salt: salt}(manager);
        console.log("Deployed hook at address:", address(hook));

        // Verify the hook address matches the computed address
        assertEq(address(hook), hookAddress, "Hook address mismatch");

        // Initialize pool
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        console.log("Initial sqrtPriceX96 to use:", initialSqrtPriceX96);

        poolKey = PoolKey({
            currency0: token0,
            currency1: token1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, initialSqrtPriceX96);
        console.log("Pool initialized successfully");

        // Add liquidity with a wider range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10000 ether,
                salt: bytes32(0)
            }),
            ""
        );
        console.log("Added initial liquidity successfully");

        // Give tokens to test users
        deal(address(Currency.unwrap(token0)), user1, 100 ether);
        deal(address(Currency.unwrap(token1)), user1, 100 ether);
        deal(address(Currency.unwrap(token0)), user2, 100 ether);
        deal(address(Currency.unwrap(token1)), user2, 100 ether);
    }

    // Fix the authorization issue in testEndToEndWorkflow
    function testEndToEndWorkflow() public {
        console.log("=== Testing End-to-End Workflow ===");

        // Step 1: Create LP positions
        console.log("\nStep 1: Creating LP positions");

        // User1 creates a position
        vm.startPrank(user1);

        // Approve tokens to the hook
        IERC20(Currency.unwrap(token0)).approve(address(hook), 10 ether);
        IERC20(Currency.unwrap(token1)).approve(address(hook), 10 ether);

        // Create position
        uint256 positionIndex1 = hook.createPosition(poolKey, -60, 60, 5 ether);
        console.log("User1 created position with index:", positionIndex1);

        vm.stopPrank();

        // User2 creates a position
        vm.startPrank(user2);

        // Approve tokens to the hook
        IERC20(Currency.unwrap(token0)).approve(address(hook), 10 ether);
        IERC20(Currency.unwrap(token1)).approve(address(hook), 10 ether);

        // Create position
        uint256 positionIndex2 = hook.createPosition(poolKey, -30, 30, 3 ether);
        console.log("User2 created position with index:", positionIndex2);

        vm.stopPrank();

        // Step 2: Simulate market activity
        console.log("\nStep 2: Simulating market activity");

        // Simulate multiple swaps to generate volatility and volume
        simulateMarketActivity();

        // Step 3: Check dynamic fee adjustment
        console.log("\nStep 3: Checking dynamic fee adjustment");

        // Get initial fee
        uint24 initialFee = hook.getDynamicFee(poolKey);
        console.log("Initial fee:", initialFee);

        // Simulate high volatility
        PoolId poolId = poolKey.toId();
        vm.startPrank(address(hook));
        hook.setVolatilityForTesting(poolId, 1500);
        vm.stopPrank();

        // Check fee after high volatility
        uint24 highVolatilityFee = hook.getDynamicFee(poolKey);
        console.log("Fee after high volatility:", highVolatilityFee);

        // Verify fee increased
        assertTrue(
            highVolatilityFee > initialFee,
            "Fee should increase with high volatility"
        );

        // Step 4: Triggering rebalancing
        console.log("\nStep 4: Triggering rebalancing");

        // Fix: Properly authorize the test contract
        // First, we need to authorize from the hook's deployer (which is this test contract)
        hook.addAuthorizedRebalancer(address(this));

        // Trigger manual rebalance
        bool rebalanceSuccess = hook.manualRebalance(poolKey);
        console.log("Rebalance success:", rebalanceSuccess ? "Yes" : "No");

        // Step 5: Check pool analytics
        console.log("\nStep 5: Checking pool analytics");

        // Get pool analytics
        AutoRebalancingHook.PoolAnalytics memory analytics = hook
            .getPoolAnalytics(poolId);
        console.log("Total volume:", analytics.totalVolume);
        console.log("Total fee revenue:", analytics.totalFeeRevenue);
        console.log("Average volatility:", analytics.averageVolatility);
        console.log("Impermanent loss estimate:", analytics.impermanentLoss);

        // Step 6: Collect fees
        console.log("\nStep 6: Collecting fees");

        // User1 collects fees
        vm.startPrank(user1);
        uint256 feesCollected1 = hook.collectFees(poolKey, positionIndex1);
        console.log("User1 collected fees:", feesCollected1);
        vm.stopPrank();

        // Step 7: Remove positions
        console.log("\nStep 7: Removing positions");

        // User2 removes position
        vm.startPrank(user2);
        uint256 liquidityRemoved = hook.removePosition(poolKey, positionIndex2);
        console.log("User2 removed liquidity:", liquidityRemoved);
        vm.stopPrank();

        console.log("\nEnd-to-end test completed successfully!");
    }

    function testMarketConditionsMonitoring() public {
        console.log("=== Testing Market Conditions Monitoring ===");

        // Get initial state
        PoolId poolId = poolKey.toId();
        AutoRebalancingHook.PoolState memory initialState = hook.getPoolState(
            poolId
        );
        console.log("Initial volatility EMA:", initialState.priceVolatilityEMA);
        console.log("Initial trading volume:", initialState.tradingVolume);

        // Simulate market activity
        simulateMarketActivity();

        // Get updated state
        AutoRebalancingHook.PoolState memory updatedState = hook.getPoolState(
            poolId
        );
        console.log("Updated volatility EMA:", updatedState.priceVolatilityEMA);
        console.log("Updated trading volume:", updatedState.tradingVolume);

        // Verify trading volume increased
        assertTrue(
            updatedState.tradingVolume > initialState.tradingVolume,
            "Trading volume should increase after market activity"
        );
    }

    function testDynamicFeeAdjustment() public {
        console.log("=== Testing Dynamic Fee Adjustment ===");

        PoolId poolId = poolKey.toId();

        // Test different market conditions and their effect on fees

        // 1. Base case
        uint24 baseFee = hook.getDynamicFee(poolKey);
        console.log("Base fee:", baseFee);

        // 2. High volatility
        vm.startPrank(address(hook));
        hook.setVolatilityForTesting(poolId, 1500);
        vm.stopPrank();

        uint24 highVolatilityFee = hook.getDynamicFee(poolKey);
        console.log("High volatility fee:", highVolatilityFee);
        assertTrue(
            highVolatilityFee > baseFee,
            "Fee should increase with high volatility"
        );

        // 3. High volume
        vm.startPrank(address(hook));
        hook.setVolatilityForTesting(poolId, 0); // Reset volatility
        hook.setVolumeForTesting(poolId, 2000 ether);
        vm.stopPrank();

        uint24 highVolumeFee = hook.getDynamicFee(poolKey);
        console.log("High volume fee:", highVolumeFee);
        assertTrue(
            highVolumeFee > baseFee,
            "Fee should increase with high volume"
        );

        // 4. Low liquidity - use direct state modification instead of modifyLiquidity
        vm.startPrank(address(hook));
        hook.setVolumeForTesting(poolId, 0); // Reset volume

        // Directly set low liquidity in the hook's state
        AutoRebalancingHook.PoolState memory state = hook.getPoolState(poolId);
        uint256 originalLiquidity = state.liquidityDepth;

        // Set a very low liquidity value (below 200 ether threshold)
        hook.setLiquidityDepthForTesting(poolId, 100 ether);
        vm.stopPrank();

        uint24 lowLiquidityFee = hook.getDynamicFee(poolKey);
        console.log("Low liquidity fee:", lowLiquidityFee);
        assertTrue(
            lowLiquidityFee > baseFee,
            "Fee should increase with low liquidity"
        );

        // Restore original liquidity
        vm.startPrank(address(hook));
        hook.setLiquidityDepthForTesting(poolId, originalLiquidity);
        vm.stopPrank();
    }

    // Fix the authorization issue in testLiquidityRebalancing
    function testLiquidityRebalancing() public {
        console.log("=== Testing Liquidity Rebalancing ===");

        PoolId poolId = poolKey.toId();

        // Create a position
        vm.startPrank(user1);

        // Approve tokens to the hook
        IERC20(Currency.unwrap(token0)).approve(address(hook), 10 ether);
        IERC20(Currency.unwrap(token1)).approve(address(hook), 10 ether);

        // Create position
        uint256 positionIndex = hook.createPosition(poolKey, -60, 60, 5 ether);

        vm.stopPrank();

        // Get initial position
        AutoRebalancingHook.LPPosition[] memory initialPositions = hook
            .getLPPositions(poolId);
        int24 initialTickLower = initialPositions[positionIndex].tickLower;
        int24 initialTickUpper = initialPositions[positionIndex].tickUpper;

        // console.log(
        //     "Initial position range:",
        //     initialTickLower,
        //     "to",
        //     initialTickUpper
        // );

        // Simulate price movement
        simulatePriceMovement();

        // Get current tick after price movement
        (, int24 currentTick, , ) = hook._getSlot0(poolId);
        console.log("Current tick after price movement:", currentTick);

        // Get pool state to check optimal range width
        AutoRebalancingHook.PoolState memory state = hook.getPoolState(poolId);
        console.log("Current range width:", state.currentRangeWidth);
        console.log("Optimal range width:", state.optimalRangeWidth);

        // Make sure the optimal range width is different from current to force rebalancing
        vm.startPrank(address(hook));
        // Set a significantly different optimal range width
        hook.setOptimalRangeWidthForTesting(poolId, 40); // Different from current width
        vm.stopPrank();

        // Check updated optimal range width
        state = hook.getPoolState(poolId);
        console.log("Updated optimal range width:", state.optimalRangeWidth);

        // Fast forward time to bypass cooldown
        vm.warp(block.timestamp + 1 hours);

        // Properly authorize the test contract
        hook.addAuthorizedRebalancer(address(this));

        // Force the current tick to be non-zero to ensure rebalancing calculations work properly
        vm.startPrank(address(hook));
        hook.setLastTickForTesting(poolId, 30); // Set a non-zero tick
        vm.stopPrank();

        // Get the current tick again
        (, currentTick, , ) = hook._getSlot0(poolId);
        console.log("Updated current tick:", currentTick);

        // Trigger rebalancing
        bool rebalanceSuccess = hook.manualRebalance(poolKey);
        console.log("Rebalance success:", rebalanceSuccess ? "Yes" : "No");
        assertTrue(rebalanceSuccess, "Rebalancing should succeed");

        // Get updated position
        AutoRebalancingHook.LPPosition[] memory updatedPositions = hook
            .getLPPositions(poolId);
        int24 updatedTickLower = updatedPositions[positionIndex].tickLower;
        int24 updatedTickUpper = updatedPositions[positionIndex].tickUpper;

        // console.log(
        //     "Updated position range:",
        //     updatedTickLower,
        //     "to",
        //     updatedTickUpper
        // );

        // Verify position was rebalanced
        assertTrue(
            updatedTickLower != initialTickLower ||
                updatedTickUpper != initialTickUpper,
            "Position should be rebalanced"
        );
    }

    function testPositionManagement() public {
        console.log("=== Testing Position Management ===");

        // User1 creates a position
        vm.startPrank(user1);

        // Approve tokens to the hook
        IERC20(Currency.unwrap(token0)).approve(address(hook), 10 ether);
        IERC20(Currency.unwrap(token1)).approve(address(hook), 10 ether);

        // Create position
        uint256 positionIndex = hook.createPosition(poolKey, -60, 60, 5 ether);

        // Get user position indexes
        PoolId poolId = poolKey.toId();
        uint256[] memory positionIndexes = hook.getUserPositionIndexes(
            user1,
            poolId
        );

        // Verify position was created
        assertEq(positionIndexes.length, 1, "User should have 1 position");
        assertEq(
            positionIndexes[0],
            positionIndex,
            "Position index should match"
        );

        // Collect fees
        uint256 feesCollected = hook.collectFees(poolKey, positionIndex);
        console.log("Fees collected:", feesCollected);

        // Remove position
        uint256 liquidityRemoved = hook.removePosition(poolKey, positionIndex);
        console.log("Liquidity removed:", liquidityRemoved);

        // Verify position was removed (marked inactive)
        AutoRebalancingHook.LPPosition[] memory positions = hook.getLPPositions(
            poolId
        );
        assertFalse(
            positions[positionIndex].active,
            "Position should be inactive"
        );

        vm.stopPrank();
    }

    // Helper function to simulate market activity
    function simulateMarketActivity() internal {
        PoolId poolId = poolKey.toId();

        // Simulate multiple swaps
        for (uint i = 0; i < 5; i++) {
            // Simulate a swap
            int256 swapAmount = -0.1 ether * int256(i + 1);

            // Update market conditions
            vm.startPrank(address(hook));
            hook.updateMarketConditionsForTesting(poolId, swapAmount);
            hook.updateMovingAverageGasPriceForTesting(poolId);
            vm.stopPrank();

            // Simulate tick changes
            (, int24 currentTick, , ) = hook._getSlot0(poolId);
            int24 newTick = currentTick - int24(int256(i) * 5);

            vm.startPrank(address(hook));
            hook.setLastTickForTesting(poolId, newTick);
            vm.stopPrank();
        }
    }

    // Helper function to simulate price movement
    function simulatePriceMovement() internal {
        PoolId poolId = poolKey.toId();

        // Get current tick
        (, int24 currentTick, , ) = hook._getSlot0(poolId);

        // Simulate a significant price movement
        int24 newTick = currentTick + 30;

        vm.startPrank(address(hook));
        hook.setLastTickForTesting(poolId, newTick);
        vm.stopPrank();

        // Update market conditions to reflect the price movement
        vm.startPrank(address(hook));
        hook.updateMarketConditionsForTesting(poolId, -1 ether);
        hook.setVolatilityForTesting(poolId, 500); // Set medium volatility
        vm.stopPrank();
    }
}
