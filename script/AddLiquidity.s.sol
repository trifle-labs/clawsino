// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/interfaces/IUniswapV4.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoolModifyLiquidityTest {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (int256 delta0, int256 delta1);
}

contract AddLiquidity is Script {
    address constant POOL_MODIFY_LIQUIDITY_TEST = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address clawToken = vm.envAddress("CLAW_TOKEN");

        console.log("Deployer:", deployer);
        console.log("WETH balance:", IERC20(WETH).balanceOf(deployer));
        console.log("CLAW balance:", IERC20(clawToken).balanceOf(deployer));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(clawToken),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(0)
        });

        vm.startBroadcast(deployerPrivateKey);

        // Approve tokens
        IERC20(WETH).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(clawToken).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);

        // Add liquidity - smaller amount
        console.log("Adding liquidity...");
        IPoolModifyLiquidityTest.ModifyLiquidityParams memory params = IPoolModifyLiquidityTest.ModifyLiquidityParams({
            tickLower: -887200,
            tickUpper: 887200,
            liquidityDelta: int256(1e17), // 0.1 liquidity units - minimal
            salt: bytes32(0)
        });

        IPoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(poolKey, params, "");
        console.log("Liquidity added!");

        vm.stopBroadcast();
    }
}
