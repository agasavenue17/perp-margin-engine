// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title CollateralVault — custody for the quote asset backing PerpMarket positions.
/// @notice Only the bound PerpMarket may move balances around. Users deposit directly.
contract CollateralVault {
    IERC20Like public immutable token;
    address public market;

    mapping(address => uint256) public balances;

    event MarketSet(address indexed market);
    event Deposited(address indexed user, uint256 amount);

    error Unauthorized();
    error MarketAlreadySet();

    constructor(address _token) {
        token = IERC20Like(_token);
    }

    /// @dev Called once by the deployer right after PerpMarket is deployed.
    function setMarket(address _market) external {
        if (market != address(0)) revert MarketAlreadySet();
        market = _market;
        emit MarketSet(_market);
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert Unauthorized();
        _;
    }

    /// @notice Pull `amount` of the quote token from `user` into custody.
    /// @dev Callable by the user themselves (needs prior ERC20 approval) or by the market.
    function depositFor(address user, uint256 amount) external {
        if (msg.sender != market && msg.sender != user) revert Unauthorized();
        bool ok = token.transferFrom(user, address(this), amount);
        require(ok, "CollateralVault: transferFrom failed");
        balances[user] += amount;
        emit Deposited(user, amount);
    }

    /// @notice Market-only: move `amount` from `from`'s balance to `to` (external).
    function debit(address from, address to, uint256 amount) external onlyMarket {
        balances[from] -= amount;
        bool ok = token.transfer(to, amount);
        require(ok, "CollateralVault: transfer failed");
    }

    /// @notice Market-only: increase `user`'s balance (profit settlement). Tokens stay in vault.
    function credit(address user, uint256 amount) external onlyMarket {
        balances[user] += amount;
    }

    /// @notice Market-only: reduce `user`'s balance without an external transfer (loss settlement).
    function burnFromBalance(address user, uint256 amount) external onlyMarket {
        balances[user] -= amount;
    }
}
