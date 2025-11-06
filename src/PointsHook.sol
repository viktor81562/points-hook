// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract PointsHook is BaseHook, ERC1155, Ownable {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error PointsHook__ZeroWeiAmount();
    error PointsHook__ZeroDailyCap();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 public minSwapWei;
    uint256 public dailyCapPerUser; // Maximum points a user can earn per day

    // user => day => points earned that day
    mapping(address => mapping(uint256 => uint256)) public dailyPointsEarned;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event MinimalSwapWeiAmount(uint256 weiAmount);
    event DailyCapUpdated(uint256 oldCap, uint256 newCap);
    event DailyCapReached(address indexed user, uint256 day, uint256 cappedPoints);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        IPoolManager _manager,
        uint256 _minSwapWei,
        uint256 _dailyCapPerUser
    ) BaseHook(_manager) Ownable(msg.sender) {
        minSwapWei = _minSwapWei;
        dailyCapPerUser = _dailyCapPerUser;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the minimum swap amount required to earn points
    /// @param weiAmount The minimum ETH amount in wei (cannot be zero)
    function setMinSwapWei(uint256 weiAmount) external onlyOwner {
        if (weiAmount == 0) {
            revert PointsHook__ZeroWeiAmount();
        }

        minSwapWei = weiAmount;

        emit MinimalSwapWeiAmount(weiAmount);
    }

    /// @notice Set the daily cap per user
    /// @param cap The maximum points a user can earn per day (cannot be zero)
    function setDailyCapPerUser(uint256 cap) external onlyOwner {
        if (cap == 0) {
            revert PointsHook__ZeroDailyCap();
        }

        uint256 oldCap = dailyCapPerUser;
        dailyCapPerUser = cap;

        emit DailyCapUpdated(oldCap, cap);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get remaining points a user can earn today
    /// @param user The address to check
    /// @return The remaining points allowance for today
    function getRemainingDailyAllowance(address user) external view returns (uint256) {
        uint256 today = getCurrentDay();
        uint256 earnedToday = dailyPointsEarned[user][today];

        if (earnedToday >= dailyCapPerUser) {
            return 0;
        }

        return dailyCapPerUser - earnedToday;
    }

    /*//////////////////////////////////////////////////////////////
                           PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get hook permissions configuration
    /// @dev Required override from BaseHook
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /*//////////////////////////////////////////////////////////////
                       PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the current day number (days since Unix epoch)
    /// @return The current day number
    function getCurrentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice Get the URI for ERC-1155 token metadata
    /// @dev Required override from ERC1155
    function uri(uint256) public view virtual override returns (string memory) {
        return "https://api.example.com/token/{id}";
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook called after a swap occurs
    /// @dev Only mints points for ETH -> TOKEN swaps above minimum threshold
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since its a zeroForOne swap:
        // if amountSpecified < 0:
        //      this is an "exact input for output" swap
        //      amount of ETH they spent is equal to |amountSpecified|
        // if amountSpecified > 0:
        //      this is an "exact output for input" swap
        //      amount of ETH they spent is equal to BalanceDelta.amount0()

        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));

        // anti-dust functionality
        if (ethSpendAmount < minSwapWei) {
            return (this.afterSwap.selector, 0);
        }

        uint256 pointsForSwap = ethSpendAmount / 5;

        // Mint the points
        _assignPoints(key.toId(), hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    /// @notice Assign points to a user with daily cap enforcement
    /// @dev Mints ERC-1155 tokens representing points, capped at daily limit
    /// @param poolId The pool ID to use as ERC-1155 token ID
    /// @param hookData Encoded user address to receive points
    /// @param points The amount of points to attempt to mint
    function _assignPoints(
        PoolId poolId,
        bytes calldata hookData,
        uint256 points
    ) internal {
        // If no hookData is passed in, no points will be assigned to anyone
        if (hookData.length == 0) return;

        // Extract user address from hookData
        address user = abi.decode(hookData, (address));

        // If there is hookData but not in the format we're expecting and user address is zero
        // nobody gets any points
        if (user == address(0)) return;

        // Apply daily cap
        uint256 today = getCurrentDay();
        uint256 earnedToday = dailyPointsEarned[user][today];
        uint256 pointsToMint = points;

        // Check if user has reached daily cap
        if (earnedToday >= dailyCapPerUser) {
            // User already hit cap, no points minted
            emit DailyCapReached(user, today, 0);
            return;
        }

        // Check if adding these points would exceed the cap
        if (earnedToday + points > dailyCapPerUser) {
            // Cap the points to not exceed daily limit
            pointsToMint = dailyCapPerUser - earnedToday;
            emit DailyCapReached(user, today, pointsToMint);
        }

        // Update daily tracking
        dailyPointsEarned[user][today] = earnedToday + pointsToMint;

        // Mint points to the user
        uint256 poolIdUint = uint256(PoolId.unwrap(poolId));
        _mint(user, poolIdUint, pointsToMint, "");
    }
}
