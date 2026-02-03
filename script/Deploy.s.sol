// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/Clawdice.sol";
import "../src/ClawdiceVault.sol";
import "../src/interfaces/IUniswapV4.sol";

/**
 * @title Deploy
 * @notice Deployment script for Clawdice contracts
 *
 * Usage:
 *   # Dry run (simulation)
 *   forge script script/Deploy.s.sol --rpc-url base_sepolia
 *
 *   # Deploy with private key
 *   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --private-key $PRIVATE_KEY
 *
 *   # Deploy and verify
 *   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify --private-key $PRIVATE_KEY
 */
contract Deploy is Script {
    // Base Sepolia addresses
    address constant WETH_BASE_SEPOLIA = 0x4200000000000000000000000000000000000006;
    address constant UNIVERSAL_ROUTER_BASE_SEPOLIA = 0x492E6456D9528771018DeB9E87ef7750EF184104;
    address constant PERMIT2_BASE_SEPOLIA = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Base Mainnet addresses
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant UNIVERSAL_ROUTER_BASE = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant PERMIT2_BASE = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        // Get deployer from private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get collateral token address from environment
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN");

        // Determine network and set addresses
        address weth;
        address universalRouter;
        address permit2;

        if (block.chainid == 84532) {
            // Base Sepolia
            weth = WETH_BASE_SEPOLIA;
            universalRouter = UNIVERSAL_ROUTER_BASE_SEPOLIA;
            permit2 = PERMIT2_BASE_SEPOLIA;
            console.log("Deploying to Base Sepolia...");
        } else if (block.chainid == 8453) {
            // Base Mainnet
            weth = WETH_BASE;
            universalRouter = UNIVERSAL_ROUTER_BASE;
            permit2 = PERMIT2_BASE;
            console.log("Deploying to Base Mainnet...");
        } else {
            revert("Unsupported chain");
        }

        console.log("Deployer:", deployer);
        console.log("Collateral Token:", collateralToken);

        vm.startBroadcast(deployerPrivateKey);

        // Create pool key for WETH/Token pair
        // Note: currency0 must be < currency1 by address
        PoolKey memory poolKey;
        if (weth < collateralToken) {
            poolKey = PoolKey({
                currency0: Currency.wrap(weth),
                currency1: Currency.wrap(collateralToken),
                fee: 10000, // 1% fee (Clanker default)
                tickSpacing: 200,
                hooks: address(0)
            });
        } else {
            poolKey = PoolKey({
                currency0: Currency.wrap(collateralToken),
                currency1: Currency.wrap(weth),
                fee: 10000,
                tickSpacing: 200,
                hooks: address(0)
            });
        }

        // Deploy Vault
        ClawdiceVault vault = new ClawdiceVault(
            collateralToken, weth, universalRouter, permit2, poolKey, "Clawdice Staked Token", "clawTOKEN"
        );
        console.log("ClawdiceVault deployed at:", address(vault));

        // Deploy Clawdice
        Clawdice clawdice = new Clawdice(address(vault), weth, universalRouter, permit2, poolKey);
        console.log("Clawdice deployed at:", address(clawdice));

        // Link vault to clawdice
        vault.setClawdice(address(clawdice));
        console.log("Vault linked to Clawdice");

        vm.stopBroadcast();

        // Output summary
        console.log("\n=== Deployment Summary ===");
        console.log("Chain ID:", block.chainid);
        console.log("ClawdiceVault:", address(vault));
        console.log("Clawdice:", address(clawdice));
        console.log("Collateral Token:", collateralToken);
        console.log("WETH:", weth);
        console.log("Universal Router:", universalRouter);
        console.log("Permit2:", permit2);
    }
}

/**
 * @title DeployMockToken
 * @notice Deploy a mock token for testing on testnets
 */
contract DeployMockToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        MockERC20 token = new MockERC20("Clawdice Test Token", "CLAW", 18);
        console.log("Mock Token deployed at:", address(token));

        // Mint some tokens to deployer
        token.mint(deployer, 1_000_000 ether);
        console.log("Minted 1,000,000 tokens to deployer");

        vm.stopBroadcast();
    }
}

/**
 * @title MockERC20
 * @notice Simple ERC20 for testing
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");

        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
        return true;
    }
}
