// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StablePair} from "../src/StablePair.sol";
import {Stablecoin} from "../src/Stablecoin.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
/// @dev This script only works on an anvil RPC because v4 exceeds bytecode limits
contract StablePairScript is Script, DeployPermit2 {
    using EasyPosm for IPositionManager;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        IPoolManager manager = deployPoolManager();
        vm.stopBroadcast();

        // hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, permissions, type(StablePair).creationCode, abi.encode(address(manager)));

        // ----------------------------- //
        // Deploy the hook using CREATE2 //
        // ----------------------------- //
        vm.broadcast();
        StablePair pair = new StablePair{salt: salt}(manager);
        require(address(pair) == hookAddress, "StablePairScript: hook address mismatch");

        // Additional helpers for interacting with the pool
        vm.startBroadcast();
        IPositionManager posm = deployPosm(manager);
        (PoolModifyLiquidityTest lpRouter, PoolSwapTest swapRouter) = deployRouters(manager);
        vm.stopBroadcast();

        // test the lifecycle (create pool, add liquidity, swap)
        vm.startBroadcast();
        testLifecycle(manager, address(pair), posm, lpRouter, swapRouter);
        vm.stopBroadcast();
    }

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------
    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A));
    }

    function deployRouters(IPoolManager manager)
        internal
        returns (PoolModifyLiquidityTest lpRouter, PoolSwapTest swapRouter)
    {
        lpRouter = PoolModifyLiquidityTest(address(0x496CD7097f0BDd32774dA3D2F1Ef0adF430b7e81));
        swapRouter = PoolSwapTest(address(0xe49d2815C231826caB58017e214Bed19fE1c2dD4));
    }

    function deployPosm(IPoolManager poolManager) public returns (IPositionManager) {
        anvilPermit2();
        return IPositionManager(new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0))));
    }

    function approvePosmCurrency(IPositionManager posm, Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }

    function deployTokens() internal returns (MockERC20 token0, MockERC20 token1, bool swapped) {
        IERC20 tokenA = IERC20(0x88541670E55cC00bEEFD87eB59EDd1b7C511AC9a);
        // MockERC20 tokenA = new MockERC20("MockA", "A", 18);
        // MockERC20 tokenB = new MockERC20("MockB", "B", 18);
        IERC20 tokenB = IERC20(address(new Stablecoin()));
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = MockERC20(address(tokenA));
            token1 = MockERC20(address(tokenB));
            swapped = true;
        } else {
            token0 = MockERC20(address(tokenB));
            token1 = MockERC20(address(tokenA));
            swapped = false;
        }
    }

    function testLifecycle(
        IPoolManager manager,
        address hook,
        IPositionManager posm,
        PoolModifyLiquidityTest lpRouter,
        PoolSwapTest swapRouter
    ) internal {
        IERC20 usdc = IERC20(0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8);
        console.logUint(usdc.balanceOf(msg.sender));
        (MockERC20 token0, MockERC20 token1, bool swapped) = deployTokens();
        if(swapped) {
            usdc.approve(address(token1), 10000000000);
            Stablecoin(address(token1)).wrap(10000000000);
        } else {
            usdc.approve(address(token0), 10000000000);
            Stablecoin(address(token0)).wrap(10000000000);
        }

        bytes memory ZERO_BYTES = new bytes(0);

        // initialize the pool
        int24 tickSpacing = 60;
        PoolKey memory poolKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, tickSpacing, IHooks(hook));
        console.logAddress(address(manager));
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Initialize the oracle
        StablePair pair = StablePair(hook);
        // pair.setOracle(address(0xdd6D76262Fd7BdDe428dcfCd94386EbAe0151603));

        // approve the tokens to the routers
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        approvePosmCurrency(posm, Currency.wrap(address(token0)));
        approvePosmCurrency(posm, Currency.wrap(address(token1)));

        // add full range liquidity to the pool
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(tickSpacing), TickMath.maxUsableTick(tickSpacing), 10000000, 0x00
            ),
            ZERO_BYTES
        );

        posm.mint(
            poolKey,
            TickMath.minUsableTick(tickSpacing),
            TickMath.maxUsableTick(tickSpacing),
            10000000,
            10_000e18,
            10_000e18,
            msg.sender,
            block.timestamp + 300,
            ZERO_BYTES
        );

        pair.addOracle(poolKey.toId(), address(0xdd6D76262Fd7BdDe428dcfCd94386EbAe0151603));

        // swap some tokens
        bool zeroForOne = true;
        int256 amountSpecified = -10000000;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
    }
}
