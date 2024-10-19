// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.13;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract StablePair is BaseHook {
    using StateLibrary for IPoolManager;

    uint256 calibrationStrength;
    uint256 targetPrice;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        calibrationStrength = 10;
        targetPrice = 10**18;
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
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
    function basePrice() public view returns (uint256) {}
    function getStablecoinPrice(PoolKey calldata key) public view returns (uint256) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint160 basePriceStablecoin = ((sqrtPriceX96 / 2**96)**2);
        uint160 stablecoinPriceBase = (1 / basePriceStablecoin);
        return uint256(stablecoinPriceBase) * basePrice();
    }
    function calculateBuyFee(uint256 inputAmount, PoolKey calldata key) public view returns (uint256) {
        uint256 stablecoinPrice = getStablecoinPrice(key);
        if(stablecoinPrice > targetPrice) {
            uint256 precentReceived = 100 - (((stablecoinPrice * 100) / targetPrice) - 100) * calibrationStrength;
            return (inputAmount * precentReceived) / 100;
        } else {
            return inputAmount;
        }
    }
    function calculateSellFee(uint256 inputAmount, PoolKey calldata key) public view returns (uint256) {
        uint256 stablecoinPrice = getStablecoinPrice(key);
        if(stablecoinPrice < targetPrice) {
            uint256 precentReceived = (100 - ((stablecoinPrice * 100) / targetPrice)) * calibrationStrength;
            return (inputAmount * precentReceived) / 100;
        } else {
            return inputAmount;
        }
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(params.amountSpecified < 0);
        uint256 inputAmount = uint256(-params.amountSpecified);
        // Take fee
        if(params.zeroForOne) {
            // Buying
            uint256 amountTaken = calculateBuyFee(inputAmount, key);
            poolManager.mint(address(this), key.currency0.toId(), amountTaken);
            poolManager.donate(key, amountTaken, 0, new bytes(0));
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int(amountTaken)), 0), 0);
        } else {
            // Selling
            uint256 amountTaken = calculateSellFee(inputAmount, key);
            poolManager.mint(address(this), key.currency1.toId(), amountTaken);
            poolManager.donate(key, 0, amountTaken, new bytes(0));
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int(amountTaken)), 0), 0);
        }
    }
}
