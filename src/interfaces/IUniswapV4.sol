// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Currency Library for Uniswap V4
/// @notice Represents a token address, with address(0) representing native ETH
type Currency is address;

/// @title PoolKey for Uniswap V4
/// @notice Identifies a unique pool
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @title IV4Router Interface (partial)
/// @notice Interface for Uniswap V4 swap routing
interface IV4Router {
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct ExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }
}

/// @title IUniversalRouter Interface (partial)
/// @notice Interface for Universal Router execute function
interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;

    /// @notice Executes encoded commands along with provided inputs
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

/// @title IPermit2 Interface (partial)
/// @notice Interface for Permit2 token approvals
interface IPermit2 {
    /// @notice Approve a spender to spend a token
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;

    /// @notice Get the allowance for a spender
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @title IWETH Interface
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title Universal Router Commands
/// @notice Command bytes for Universal Router
library Commands {
    // V4 Swap command
    uint8 internal constant V4_SWAP = 0x10;
    // Wrap ETH
    uint8 internal constant WRAP_ETH = 0x0b;
    // Unwrap WETH
    uint8 internal constant UNWRAP_WETH = 0x0c;
    // Permit2 transfer from
    uint8 internal constant PERMIT2_TRANSFER_FROM = 0x02;
}

/// @title V4 Router Actions
/// @notice Action bytes for V4 router (must match v4-periphery/src/libraries/Actions.sol)
library Actions {
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SWAP_EXACT_IN = 0x07;
    uint8 internal constant SETTLE_ALL = 0x0c; // Fixed: was 0x12
    uint8 internal constant TAKE_ALL = 0x0f; // Fixed: was 0x15
}
