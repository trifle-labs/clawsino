// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IUniswapV4.sol";

/// @title ClawdiceVault
/// @notice ERC-4626 vault for Clawdice staking using any ERC20 token as collateral
/// @dev Supports Uniswap V4 swaps for ETH deposits and ERC20 permit for gasless approvals
contract ClawdiceVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public clawdice;
    IERC20 public immutable collateralToken;
    IWETH public immutable weth;
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;

    // Uniswap V4 pool configuration
    PoolKey public poolKey;

    event ClawdiceSet(address indexed clawdice);
    event Staked(address indexed staker, uint256 assets, uint256 shares);
    event Unstaked(address indexed staker, uint256 shares, uint256 assets);
    event PoolKeyUpdated(PoolKey oldKey, PoolKey newKey);

    constructor(
        address _collateralToken,
        address _weth,
        address _universalRouter,
        address _permit2,
        PoolKey memory _poolKey,
        string memory _name,
        string memory _symbol
    ) ERC4626(IERC20(_collateralToken)) ERC20(_name, _symbol) Ownable(msg.sender) {
        collateralToken = IERC20(_collateralToken);
        weth = IWETH(_weth);
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);
        poolKey = _poolKey;

        // Approve Permit2 for WETH (Universal Router uses Permit2)
        IERC20(_weth).approve(_permit2, type(uint256).max);
        // Approve Universal Router via Permit2
        IPermit2(_permit2).approve(_weth, _universalRouter, type(uint160).max, type(uint48).max);
    }

    /// @notice Set the Clawdice contract address (one-time)
    function setClawdice(address _clawdice) external onlyOwner {
        require(clawdice == address(0), "Already set");
        require(_clawdice != address(0), "Invalid address");
        clawdice = _clawdice;
        emit ClawdiceSet(_clawdice);
    }

    /// @notice Update pool key for V4 swaps
    function setPoolKey(PoolKey memory _poolKey) external onlyOwner {
        PoolKey memory oldKey = poolKey;
        poolKey = _poolKey;
        emit PoolKeyUpdated(oldKey, _poolKey);
    }

    /// @notice Stake tokens directly and receive vault shares
    /// @param assets Amount of collateral tokens to stake
    function stake(uint256 assets) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "Zero assets");

        // Calculate shares BEFORE transfer
        shares = _convertToShares(assets);
        require(shares > 0, "Zero shares");

        // Transfer tokens from sender
        collateralToken.safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares to sender
        _mint(msg.sender, shares);

        emit Staked(msg.sender, assets, shares);
    }

    /// @notice Stake tokens using ERC20 permit (gasless approval)
    /// @param assets Amount of collateral tokens to stake
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function stakeWithPermit(uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(assets > 0, "Zero assets");

        // Execute permit
        IERC20Permit(address(collateralToken)).permit(msg.sender, address(this), assets, deadline, v, r, s);

        // Calculate shares BEFORE transfer
        shares = _convertToShares(assets);
        require(shares > 0, "Zero shares");

        // Transfer tokens from sender
        collateralToken.safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares to sender
        _mint(msg.sender, shares);

        emit Staked(msg.sender, assets, shares);
    }

    /// @notice Stake with ETH - swaps to collateral token via Uniswap V4
    /// @param minTokensOut Minimum tokens to receive from swap (slippage protection)
    function stakeWithETH(uint256 minTokensOut) external payable nonReentrant returns (uint256 shares) {
        require(msg.value > 0, "No ETH sent");

        // Swap ETH -> collateral token via V4
        uint256 tokensReceived = _swapETHForTokens(msg.value, minTokensOut);

        // Calculate shares
        shares = _convertToShares(tokensReceived);
        require(shares > 0, "Zero shares");

        // Mint shares to sender
        _mint(msg.sender, shares);

        emit Staked(msg.sender, tokensReceived, shares);
    }

    /// @notice Internal function to swap ETH for tokens via Uniswap V4 Universal Router
    function _swapETHForTokens(uint256 ethAmount, uint256 minTokensOut) internal returns (uint256 tokensReceived) {
        uint256 balanceBefore = collateralToken.balanceOf(address(this));

        // Wrap ETH to WETH
        weth.deposit{ value: ethAmount }();

        // Determine swap direction based on pool key
        // currency0 < currency1 by convention
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(weth);

        // Encode V4 swap actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Encode swap parameters
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(ethAmount),
                amountOutMinimum: uint128(minTokensOut),
                hookData: bytes("")
            })
        );

        // Settle input token (WETH)
        if (zeroForOne) {
            params[1] = abi.encode(poolKey.currency0, ethAmount);
            params[2] = abi.encode(poolKey.currency1, minTokensOut);
        } else {
            params[1] = abi.encode(poolKey.currency1, ethAmount);
            params[2] = abi.encode(poolKey.currency0, minTokensOut);
        }

        // Encode Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // Execute swap
        universalRouter.execute(commands, inputs, block.timestamp + 60);

        // Calculate tokens received
        tokensReceived = collateralToken.balanceOf(address(this)) - balanceBefore;
        require(tokensReceived >= minTokensOut, "Insufficient output");
    }

    /// @notice Convert assets to shares, handling zero supply case
    function _convertToShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets; // 1:1 for first deposit
        }
        return (assets * supply) / totalAssets();
    }

    /// @notice Convert shares to assets
    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares; // 1:1 when no supply
        }
        return (shares * totalAssets()) / supply;
    }

    /// @notice Unstake by burning shares and receiving collateral tokens
    function unstake(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");

        // Calculate assets
        assets = _convertToAssets(shares);
        require(assets > 0, "Zero assets");

        // Check we have enough tokens
        require(collateralToken.balanceOf(address(this)) >= assets, "Insufficient liquidity");

        // Burn shares
        _burn(msg.sender, shares);

        // Transfer tokens
        collateralToken.safeTransfer(msg.sender, assets);

        emit Unstaked(msg.sender, shares, assets);
    }

    /// @notice Get total assets (collateral token balance)
    function totalAssets() public view override returns (uint256) {
        return collateralToken.balanceOf(address(this));
    }

    /// @notice Receive tokens from Clawdice (bet losses)
    function receiveFromClawdice(uint256 amount) external {
        require(msg.sender == clawdice, "Only Clawdice");
        // Tokens are already transferred via safeTransfer before this call
        // This function is just for event tracking if needed
    }

    /// @notice Withdraw tokens to pay Clawdice winners
    /// @param amount Amount of tokens to withdraw
    function withdrawForPayout(uint256 amount) external nonReentrant {
        require(msg.sender == clawdice, "Only Clawdice");
        require(collateralToken.balanceOf(address(this)) >= amount, "Insufficient funds");

        collateralToken.safeTransfer(clawdice, amount);
    }

    /// @notice Seed initial liquidity (owner only, for initial setup)
    function seedLiquidity(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        // Mint shares to owner (1:1 for initial deposit)
        uint256 shares = amount;
        _mint(msg.sender, shares);

        emit Staked(msg.sender, amount, shares);
    }

    /// @notice Emergency withdraw all tokens (owner only)
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = collateralToken.balanceOf(address(this));
        if (balance > 0) {
            collateralToken.safeTransfer(owner(), balance);
        }
    }

    /// @notice Refund any ETH sent directly (shouldn't happen but safety net)
    receive() external payable {
        // Only accept ETH from WETH unwrap
        require(msg.sender == address(weth), "Use stakeWithETH");
    }
}
