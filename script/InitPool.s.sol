// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/interfaces/IUniswapV4.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoolManager {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

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

contract InitPool is Script {
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant POOL_MODIFY_LIQUIDITY_TEST = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address clawToken = vm.envAddress("CLAW_TOKEN");

        console.log("Deployer:", deployer);
        console.log("CLAW Token:", clawToken);
        console.log("WETH:", WETH);

        // Create pool key - currency0 must be < currency1
        PoolKey memory poolKey;
        if (WETH < clawToken) {
            poolKey = PoolKey({
                currency0: Currency.wrap(WETH),
                currency1: Currency.wrap(clawToken),
                fee: 10000,
                tickSpacing: 200,
                hooks: address(0)
            });
        } else {
            poolKey = PoolKey({
                currency0: Currency.wrap(clawToken),
                currency1: Currency.wrap(WETH),
                fee: 10000,
                tickSpacing: 200,
                hooks: address(0)
            });
        }

        // sqrt(1) * 2^96 for 1:1 price ratio
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        vm.startBroadcast(deployerPrivateKey);

        // Initialize pool
        console.log("Initializing pool...");
        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);
        console.log("Pool initialized!");

        // Approve tokens for liquidity test contract
        IERC20(WETH).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(clawToken).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);

        // Add liquidity - wide range
        console.log("Adding liquidity...");
        IPoolModifyLiquidityTest.ModifyLiquidityParams memory params = IPoolModifyLiquidityTest.ModifyLiquidityParams({
            tickLower: -887200, // min tick for 200 spacing
            tickUpper: 887200, // max tick for 200 spacing
            liquidityDelta: int256(1000 * 1e18), // 1k liquidity units (smaller for testing)
            salt: bytes32(0)
        });

        IPoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(poolKey, params, "");
        console.log("Liquidity added!");

        vm.stopBroadcast();
    }
}
