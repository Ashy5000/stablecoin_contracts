// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.13;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract StablePair is BaseHook {
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function getStablecoinPrice() returns (uint256) {}
    function calculateBuyFee() returns (uint256) {}
    function calculateSellFee() returns (uint256) {}

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata) {
        require(params.amountSpecified < 0);
        // Take fee
        if(params.zeroForOne) {
            // Buying
            uint256 amountTaken = calculateBuyFee();
            poolManager.mint(address(this), key.currency0.toId(), amountTaken);
            poolManager.donate(key, amountTaken, 0, new bytes(0));
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(amountTaken.toInt128(), 0), 0);
        } else {
            // Selling
            uint256 amountTaken = calculateSellFee();
            poolManager.mint(address(this), key.currency1.toId(), amountTaken);
            poolManager.donate(key, 0, amountTaken, new bytes(0));
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(amountTaken.toInt128(), 0), 0);
        }
    }
}
