// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract DeployHook is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        PoolManager manager = new PoolManager(address(0));

        uint256 minSwapWei = 0.0001 ether;
        uint256 dailyCap = 10 * 1e18;

        PointsHook hook = new PointsHook(manager, minSwapWei, dailyCap);

        vm.stopBroadcast();
    }
}
