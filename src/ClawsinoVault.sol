// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title WETH9 Minimal Interface
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @title ClawsinoVault
/// @notice ERC-4626 vault for Clawsino staking, using native ETH
/// @dev Wraps ETH to WETH for ERC-4626 compatibility
contract ClawsinoVault is ERC4626, Ownable, ReentrancyGuard {
    address public clawsino;
    IWETH public immutable weth;

    event ClawsinoSet(address indexed clawsino);
    event Staked(address indexed staker, uint256 assets, uint256 shares);
    event Unstaked(address indexed staker, uint256 shares, uint256 assets);

    constructor(
        address _weth
    ) ERC4626(IERC20(_weth)) ERC20("Clawsino Staked ETH", "clawETH") Ownable(msg.sender) {
        weth = IWETH(_weth);
    }

    /// @notice Set the Clawsino contract address (one-time)
    function setClawsino(address _clawsino) external onlyOwner {
        require(clawsino == address(0), "Already set");
        require(_clawsino != address(0), "Invalid address");
        clawsino = _clawsino;
        emit ClawsinoSet(_clawsino);
    }

    /// @notice Stake ETH and receive clawETH shares
    function stake() external payable nonReentrant returns (uint256 shares) {
        require(msg.value > 0, "No ETH sent");

        // Calculate shares BEFORE depositing (so totalAssets doesn't include new deposit)
        shares = _convertToShares(msg.value);
        require(shares > 0, "Zero shares");

        // Wrap ETH to WETH
        weth.deposit{value: msg.value}();

        // Mint shares to sender
        _mint(msg.sender, shares);

        emit Staked(msg.sender, msg.value, shares);
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

    /// @notice Unstake by burning shares and receiving ETH
    function unstake(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= shares, "Insufficient shares");

        // Calculate assets
        assets = _convertToAssets(shares);
        require(assets > 0, "Zero assets");

        // Check we have enough WETH
        require(weth.balanceOf(address(this)) >= assets, "Insufficient liquidity");

        // Burn shares
        _burn(msg.sender, shares);

        // Unwrap WETH and send ETH
        weth.withdraw(assets);
        (bool success,) = msg.sender.call{value: assets}("");
        require(success, "ETH transfer failed");

        emit Unstaked(msg.sender, shares, assets);
    }

    /// @notice Get total assets (WETH balance)
    function totalAssets() public view override returns (uint256) {
        return weth.balanceOf(address(this));
    }

    /// @notice Handle incoming ETH from Clawsino (bet losses) or WETH (unwrap)
    receive() external payable {
        // Accept from WETH (for withdraw) or Clawsino (for bet losses)
        if (msg.sender == address(weth)) {
            // ETH from WETH unwrap, do nothing (will be sent to user)
            return;
        }
        require(msg.sender == clawsino, "Only Clawsino or WETH");
        // Wrap incoming ETH to WETH
        weth.deposit{value: msg.value}();
    }

    /// @notice Withdraw ETH to pay Clawsino winners
    /// @param amount Amount of ETH to withdraw
    function withdrawForPayout(uint256 amount) external nonReentrant {
        require(msg.sender == clawsino, "Only Clawsino");
        require(weth.balanceOf(address(this)) >= amount, "Insufficient funds");

        weth.withdraw(amount);
        (bool success,) = clawsino.call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// @notice Seed initial liquidity (owner only, for initial setup)
    function seedLiquidity() external payable onlyOwner {
        require(msg.value > 0, "No ETH");
        weth.deposit{value: msg.value}();
        // Mint shares to owner
        uint256 shares = msg.value; // 1:1 for initial deposit
        _mint(msg.sender, shares);
        emit Staked(msg.sender, msg.value, shares);
    }

    /// @notice Emergency withdraw all WETH as ETH (owner only)
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = weth.balanceOf(address(this));
        if (balance > 0) {
            weth.withdraw(balance);
            (bool success,) = owner().call{value: balance}("");
            require(success, "Transfer failed");
        }
    }

    // Standard ERC-4626 deposit/withdraw use WETH directly
    // Users should use stake()/unstake() for ETH interactions
}
