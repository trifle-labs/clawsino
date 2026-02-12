// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/interfaces/IUniswapV4.sol";

interface IPoolManager {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

contract InitPoolOnly is Script {
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address clawToken = vm.envAddress("CLAW_TOKEN");

        console.log("Initializing WETH/CLAW pool on Base Sepolia...");

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(clawToken),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(0)
        });

        // sqrt(1) * 2^96 for 1:1 price
        uint160 sqrtPriceX96 = 79228162514264337593543950336;

        vm.startBroadcast(deployerPrivateKey);
        int24 tick = IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtPriceX96);
        console.log("Pool initialized at tick:", tick);
        vm.stopBroadcast();
    }
}
