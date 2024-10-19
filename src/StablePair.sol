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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IChronicle} from "./IChronicle.sol";
import {ISelfKisser} from "./ISelfKisser.sol";

contract StablePair is BaseHook {
    using StateLibrary for IPoolManager;

    uint256 calibrationStrength;
    uint256 targetPrice;

    address owner;

    ISelfKisser public selfKisser = ISelfKisser(address(0x0Dcc19657007713483A5cA76e6A7bbe5f56EA37d));
    // mapping(PoolId => IChronicle) public oracles;
    IChronicle public oracle;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        calibrationStrength = 10;
        targetPrice = 10**18;
        owner = msg.sender;
    }

    // function addOracle(PoolId key, address oracle) public {
    //     selfKisser.selfKiss(oracle);
    //     oracles[key] = IChronicle(oracle);
    // }

    function setOracle(address oracleAddress) public {
        selfKisser.selfKiss(oracleAddress);
        oracle = IChronicle(oracleAddress);
    }

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    // function basePrice(PoolId id) public view returns (uint256) {
    function basePrice() public view returns (uint256) {
        return oracle.read();
    }
    function getStablecoinPrice(PoolKey calldata key) public view returns (uint256) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        uint160 basePriceStablecoin = ((sqrtPriceX96 / 2**96)**2);
        uint160 stablecoinPriceBase = (1 / basePriceStablecoin);
        return uint256(stablecoinPriceBase) * basePrice();
    }
    function calculateBuyFee(PoolKey calldata key) public view returns (uint256) {
        uint256 stablecoinPrice = getStablecoinPrice(key);
        if(stablecoinPrice > targetPrice) {
            uint256 feePrecentage = (((stablecoinPrice * 100) / targetPrice) - 100) * calibrationStrength;
            uint256 precentReceived = 0;
            if(feePrecentage >= 50) {
                precentReceived = 50; // Hard limit at 50% fee
            } else {
                precentReceived = 100 - feePrecentage;
            }
            return precentReceived * 10000;
        } else {
            return 0;
        }
    }
    function calculateSellFee(PoolKey calldata key) public view returns (uint256) {
        uint256 stablecoinPrice = getStablecoinPrice(key);
        if(stablecoinPrice < targetPrice) {
            uint256 feePrecentage = ((stablecoinPrice * 100) / targetPrice) * calibrationStrength;
            uint256 precentReceived = 0;
            if(feePrecentage >= 50) {
                precentReceived = 50; // Hard limit at 50% fee
            } else {
                precentReceived = 100 - feePrecentage;
            }
            return precentReceived * 10000;
        } else {
            return 0;
        }
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(params.amountSpecified < 0);
        // Take fee
        if(params.zeroForOne) {
            // Buying
            uint256 fee = calculateBuyFee(key);
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), uint24(fee + 500) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        } else {
            // Selling
            uint256 fee = calculateSellFee(key);
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), uint24(fee + 500) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }
    }
}
