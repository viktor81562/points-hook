// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        uint256 minSwapWei = 0.0001 ether; // Set minimum swap amount
        uint256 dailyCapPerUser = 1 ether; // Set daily cap to 1 ether worth of points
        deployCodeTo("PointsHook.sol", abi.encode(manager, minSwapWei, dailyCapPerUser), address(flags));

        // Deploy our hook
        hook = PointsHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees 0.3%
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        // Use wider range and more liquidity to support large swaps
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(600);

        uint256 ethToAdd = 100 ether; // Increase liquidity to support 10 ETH swaps
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );
        uint256 tokenToAdd = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtPriceAtTickLower,
            SQRT_PRICE_1_1,
            liquidityDelta
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(
            address(this),
            poolIdUint
        );

        // Set user address in hook data
        bytes memory hookData = abi.encode(address(this));

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(
            address(this),
            poolIdUint
        );
        assertEq(pointsBalanceAfterSwap - pointsBalanceOriginal, 2 * 10 ** 14);
    }

    // ===== ANTI-DUST TESTS =====

    /// @notice Test that swaps below minimum don't mint points
    function test_antiDust_BelowMinimum_NoPoints() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        // Get initial balance
        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        // Swap BELOW the minimum (0.0001 ether)
        // We're swapping 0.00005 ether which is less than minSwapWei
        swapRouter.swap{value: 0.00005 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.00005 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        // Points should NOT increase
        uint256 pointsAfter = hook.balanceOf(address(this), poolIdUint);
        assertEq(pointsAfter, pointsBefore, "Dust swap should not mint points");
    }

    /// @notice Test that swaps exactly at minimum DO mint points
    function test_antiDust_ExactlyAtMinimum_MintsPoints() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        // Swap EXACTLY at the minimum (0.0001 ether)
        swapRouter.swap{value: 0.0001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.0001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        // Points SHOULD increase: 20% of 0.0001 ether = 0.00002 ether = 2e13
        uint256 pointsAfter = hook.balanceOf(address(this), poolIdUint);
        uint256 expectedPoints = 0.0001 ether / 5;
        assertEq(pointsAfter - pointsBefore, expectedPoints, "Should mint points for minimum swap");
    }

    /// @notice Test that swaps above minimum mint correct points
    function test_antiDust_AboveMinimum_MintsCorrectPoints() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        // Swap well above minimum
        uint256 swapAmount = 0.01 ether;
        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsAfter = hook.balanceOf(address(this), poolIdUint);
        uint256 expectedPoints = swapAmount / 5; // 20% = divide by 5
        assertEq(pointsAfter - pointsBefore, expectedPoints, "Should mint 20% of swap amount");
    }

    /// @notice Test that owner can update minSwapWei
    function test_antiDust_OwnerCanUpdateMinimum() public {
        // Initial value set in setUp: 0.0001 ether
        assertEq(hook.minSwapWei(), 0.0001 ether);

        // Update to new value
        uint256 newMin = 0.001 ether;
        hook.setMinSwapWei(newMin);

        assertEq(hook.minSwapWei(), newMin, "Minimum should be updated");
    }

    /// @notice Test that non-owner cannot update minSwapWei
    function test_antiDust_NonOwnerCannotUpdate() public {
        // Prank as address(1) who is not the owner
        vm.prank(address(1));

        // This should revert with Ownable error
        vm.expectRevert();
        hook.setMinSwapWei(0.002 ether);
    }

    /// @notice Test that setting minSwapWei to 0 reverts
    function test_antiDust_CannotSetToZero() public {
        // Try to set to 0, should revert
        vm.expectRevert(PointsHook.PointsHook__ZeroWeiAmount.selector);
        hook.setMinSwapWei(0);
    }

    /// @notice Test multiple small swaps don't accumulate points
    function test_antiDust_MultipleSmallSwaps_NoAccumulation() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        // Do 10 dust swaps
        for (uint i = 0; i < 10; i++) {
            swapRouter.swap{value: 0.00001 ether}(
                key,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -0.00001 ether,
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({
                    takeClaims: false,
                    settleUsingBurn: false
                }),
                hookData
            );
        }

        uint256 pointsAfter = hook.balanceOf(address(this), poolIdUint);

        // Even though total = 0.0001 ether (at minimum),
        // individual swaps were below minimum so NO points minted
        assertEq(pointsAfter, pointsBefore, "Dust swaps should never accumulate points");
    }

    // ===== DAILY CAP TESTS =====

    /// @notice Test that daily cap is enforced
    function test_dailyCap_EnforcedCorrectly() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        // Daily cap is 1 ether worth of points
        // Do a large swap that would normally give more than 1 ether in points
        // Swapping 10 ether would normally give 2 ether in points (20%)
        // But should be capped at 1 ether
        uint256 pointsBefore = hook.balanceOf(address(this), poolIdUint);

        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsAfter = hook.balanceOf(address(this), poolIdUint);

        // Should only receive 1 ether (the cap), not 2 ether
        assertEq(pointsAfter - pointsBefore, 1 ether, "Points should be capped at daily limit");
    }

    /// @notice Test that no points are minted once daily cap is reached
    function test_dailyCap_NoPointsAfterCapReached() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        // First swap: reach the daily cap
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsAfterFirst = hook.balanceOf(address(this), poolIdUint);

        // Second swap: should get 0 points as cap already reached
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsAfterSecond = hook.balanceOf(address(this), poolIdUint);

        assertEq(pointsAfterSecond, pointsAfterFirst, "No points should be minted after cap reached");
    }

    /// @notice Test that daily cap resets on new day
    function test_dailyCap_ResetsOnNewDay() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookData = abi.encode(address(this));

        // Day 1: Reach cap
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsDay1 = hook.balanceOf(address(this), poolIdUint);

        // Fast forward to next day (86400 seconds = 1 day)
        vm.warp(block.timestamp + 1 days);

        // Day 2: Should be able to earn points again
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 pointsDay2 = hook.balanceOf(address(this), poolIdUint);

        // Should have earned 0.2 ether more points (20% of 1 ether)
        assertEq(pointsDay2 - pointsDay1, 0.2 ether, "Should earn points again on new day");
    }

    /// @notice Test that owner can update daily cap
    function test_dailyCap_OwnerCanUpdate() public {
        assertEq(hook.dailyCapPerUser(), 1 ether);

        uint256 newCap = 5 ether;
        hook.setDailyCapPerUser(newCap);

        assertEq(hook.dailyCapPerUser(), newCap, "Daily cap should be updated");
    }

    /// @notice Test that non-owner cannot update daily cap
    function test_dailyCap_NonOwnerCannotUpdate() public {
        vm.prank(address(1));

        vm.expectRevert();
        hook.setDailyCapPerUser(5 ether);
    }

    /// @notice Test that daily cap cannot be set to zero
    function test_dailyCap_CannotSetToZero() public {
        vm.expectRevert(PointsHook.PointsHook__ZeroDailyCap.selector);
        hook.setDailyCapPerUser(0);
    }

    /// @notice Test getRemainingDailyAllowance function
    function test_dailyCap_RemainingAllowance() public {
        address user = address(this);

        // Initially should have full allowance
        assertEq(hook.getRemainingDailyAllowance(user), 1 ether);

        bytes memory hookData = abi.encode(user);

        // Swap to earn some points (0.2 ether worth)
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        // Remaining should be 0.8 ether
        assertEq(hook.getRemainingDailyAllowance(user), 0.8 ether);

        // Reach the cap
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        // Remaining should be 0
        assertEq(hook.getRemainingDailyAllowance(user), 0);
    }

    /// @notice Test that different users have independent daily caps
    function test_dailyCap_IndependentPerUser() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        address user1 = address(this);
        address user2 = address(1);

        // User1 reaches cap
        bytes memory hookData1 = abi.encode(user1);
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -10 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData1
        );

        // User1 should have full cap
        assertEq(hook.getRemainingDailyAllowance(user1), 0);

        // User2 should still have full allowance
        assertEq(hook.getRemainingDailyAllowance(user2), 1 ether);
    }
}
