// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/Clawdice.sol";
import "../src/ClawdiceVault.sol";
import "../src/interfaces/IUniswapV4.sol";

contract RedeployClawdice is Script {
    // Base Sepolia addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant UNIVERSAL_ROUTER = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant CLAW_TOKEN = 0xD2C1CB4556ca49Ac6C7A5bc71657bD615500057c;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Deploying fresh Vault + Clawdice...");

        // Create pool key (WETH < CLAW by address)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(CLAW_TOKEN),
            fee: 10000,
            tickSpacing: 200,
            hooks: address(0)
        });

        vm.startBroadcast(deployerPrivateKey);

        // Deploy fresh Vault first
        ClawdiceVault vault =
            new ClawdiceVault(CLAW_TOKEN, WETH, UNIVERSAL_ROUTER, PERMIT2, poolKey, "Clawdice Vault", "vCLAW");
        console.log("New Vault deployed at:", address(vault));

        // Deploy new Clawdice pointing to fresh vault
        Clawdice clawdice = new Clawdice(address(vault), WETH, UNIVERSAL_ROUTER, PERMIT2, poolKey);
        console.log("New Clawdice deployed at:", address(clawdice));

        // Link vault to clawdice
        vault.setClawdice(address(clawdice));
        console.log("Vault linked to Clawdice");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Vault:", address(vault));
        console.log("Clawdice:", address(clawdice));
        console.log("");
        console.log("Next steps:");
        console.log("1. Stake CLAW to vault for bankroll");
        console.log("2. Update frontend contract addresses");
        console.log("3. Verify contracts on Basescan");
    }
}
