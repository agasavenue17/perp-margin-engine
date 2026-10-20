// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CollateralVault.sol";
import "./mocks/MockOracle.sol";

/// @title PerpMarket — minimal perpetual futures margin engine.
/// @notice Educational reference implementation. Collateral is a single ERC20 quote asset
///         (mUSD). One position per trader. Prices come from an oracle (mocked in this repo).
///         NOT audited, NOT for production use.
contract PerpMarket {
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_LEVERAGE = 20;
    uint256 public constant MAINTENANCE_MARGIN_BPS = 625; // 6.25% of notional
    uint256 public constant LIQUIDATOR_BONUS_BPS = 200; // 2% of remaining equity

    CollateralVault public immutable vault;
    MockOracle public immutable oracle;

    address public owner;
    address public keeper; // authorized to push funding updates

    struct Position {
        uint256 sizeUsd; // notional, 1e18
        uint256 entryPrice; // 1e18
        bool isLong;
        uint256 margin; // initial margin posted, 1e18
        uint256 openedAt;
        int256 fundingPaid; // >0: trader paid funding (reduces equity)
    }

    mapping(address => Position) private _positions;
    address[] public traders;
    mapping(address => bool) private _knownTrader;

    event PositionOpened(
        address indexed trader, bool isLong, uint256 sizeUsd, uint256 entryPrice, uint256 leverage
    );
    event PositionClosed(address indexed trader, int256 pnl, uint256 exitPrice);
    event PositionLiquidated(address indexed trader, address indexed liquidator, uint256 bonus);
    event FundingAccrued(int256 rateBps, uint256 periodSeconds);
    event KeeperSet(address indexed keeper);

    error InsufficientCollateral();
    error PositionExists();
    error NoPosition();
    error InvalidLeverage();
    error NotLiquidatable();
    error Unauthorized();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _vault, address _oracle) {
        vault = CollateralVault(_vault);
        oracle = MockOracle(_oracle);
        owner = msg.sender;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    // -------------------------------------------------------------------------
    // Collateral
    // -------------------------------------------------------------------------

    /// @notice Deposit quote tokens as collateral (caller must approve the vault first).
    function deposit(uint256 amount) external {
        vault.depositFor(msg.sender, amount);
    }

    /// @notice Withdraw free collateral. Blocked while a position is open.
    function withdraw(uint256 amount) external {
        if (_positions[msg.sender].sizeUsd != 0) revert PositionExists();
        vault.debit(msg.sender, msg.sender, amount);
    }

    function collateralOf(address trader) external view returns (uint256) {
        return vault.balances(trader);
    }

    // -------------------------------------------------------------------------
    // Positions
    // -------------------------------------------------------------------------

    /// @notice Open a leveraged perpetual position.
    /// @param isLong Direction of the position.
    /// @param sizeUsd Notional size in USD (1e18).
    /// @param leverage Leverage multiplier, 1..MAX_LEVERAGE.
    function openPosition(bool isLong, uint256 sizeUsd, uint256 leverage) external {
        if (leverage == 0 || leverage > MAX_LEVERAGE) revert InvalidLeverage();
        if (_positions[msg.sender].sizeUsd != 0) revert PositionExists();
        if (sizeUsd == 0) revert InsufficientCollateral();

        uint256 marginRequired = sizeUsd / leverage;
        if (vault.balances(msg.sender) < marginRequired) revert InsufficientCollateral();

        uint256 price = oracle.latestPrice();
        _positions[msg.sender] = Position({
            sizeUsd: sizeUsd,
            entryPrice: price,
            isLong: isLong,
            margin: marginRequired,
            openedAt: block.timestamp,
            fundingPaid: 0
        });

        if (!_knownTrader[msg.sender]) {
            _knownTrader[msg.sender] = true;
            traders.push(msg.sender);
        }

        emit PositionOpened(msg.sender, isLong, sizeUsd, price, leverage);
    }

    /// @notice Close the caller's position at the current oracle price.
    function closePosition() external {
        Position memory p = _positions[msg.sender];
        if (p.sizeUsd == 0) revert NoPosition();

        uint256 exitPrice = oracle.latestPrice();
        int256 pnl = unrealizedPnL(msg.sender);
        int256 delta = pnl - p.fundingPaid; // net change to the collateral balance

        uint256 bal = vault.balances(msg.sender);
        if (delta >= 0) {
            vault.credit(msg.sender, uint256(delta));
        } else {
            uint256 loss = uint256(-delta);
            uint256 take = loss > bal ? bal : loss;
            if (take > 0) vault.burnFromBalance(msg.sender, take);
        }

        delete _positions[msg.sender];
        emit PositionClosed(msg.sender, pnl, exitPrice);
    }

    function getPosition(address trader) external view returns (Position memory) {
        return _positions[trader];
    }

    // -------------------------------------------------------------------------
    // Accounting
    // -------------------------------------------------------------------------

    /// @notice Mark-to-market PnL of a trader's open position (1e18, signed).
    function unrealizedPnL(address trader) public view returns (int256) {
        Position memory p = _positions[trader];
        if (p.sizeUsd == 0) return 0;
        uint256 price = oracle.latestPrice();
        int256 priceDelta = p.isLong
            ? int256(price) - int256(p.entryPrice)
            : int256(p.entryPrice) - int256(price);
        return (priceDelta * int256(p.sizeUsd)) / int256(p.entryPrice);
    }

    /// @notice Total account value: collateral + unrealized PnL - net funding paid.
    function equity(address trader) public view returns (int256) {
        Position memory p = _positions[trader];
        int256 bal = int256(vault.balances(trader));
        if (p.sizeUsd == 0) return bal;
        return bal + unrealizedPnL(trader) - p.fundingPaid;
    }

    /// @notice True when equity fell below the maintenance margin requirement.
    function isLiquidatable(address trader) public view returns (bool) {
        Position memory p = _positions[trader];
        if (p.sizeUsd == 0) return false;
        int256 maintenanceMargin = (int256(p.sizeUsd) * int256(MAINTENANCE_MARGIN_BPS)) / 10000;
        return equity(trader) < maintenanceMargin;
    }

    /// @notice Close an underwater position. Caller receives a bonus from remaining equity.
    function liquidate(address trader) external {
        if (!isLiquidatable(trader)) revert NotLiquidatable();

        int256 eq = equity(trader);
        uint256 traderBal = vault.balances(trader);
        uint256 bonus = 0;

        if (eq > 0) {
            bonus = (uint256(eq) * LIQUIDATOR_BONUS_BPS) / 10000;
            uint256 target = uint256(eq); // trader's balance should equal remaining equity
            if (target >= traderBal) {
                vault.credit(trader, target - traderBal);
            } else {
                vault.burnFromBalance(trader, traderBal - target);
            }
            vault.debit(trader, msg.sender, bonus); // pay the liquidator
        } else if (traderBal > 0) {
            vault.burnFromBalance(trader, traderBal); // nothing left for the trader
        }

        delete _positions[trader];
        emit PositionLiquidated(trader, msg.sender, bonus);
    }

    // -------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------

    /// @notice Apply a funding rate to every open position (called by the keeper).
    /// @param rateBps Funding rate in basis points for `periodSeconds`. Positive => longs pay shorts.
    function accrueFunding(int256 rateBps, uint256 periodSeconds) external {
        if (msg.sender != keeper) revert Unauthorized();
        uint256 n = traders.length;
        for (uint256 i = 0; i < n; i++) {
            Position storage p = _positions[traders[i]];
            if (p.sizeUsd == 0) continue;
            int256 payment = (int256(p.sizeUsd) * rateBps * int256(periodSeconds)) / 10000 / 1 days;
            if (p.isLong) {
                p.fundingPaid += payment;
            } else {
                p.fundingPaid -= payment;
            }
        }
        emit FundingAccrued(rateBps, periodSeconds);
    }
}
