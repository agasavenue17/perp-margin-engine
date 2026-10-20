// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/PerpMarket.sol";
import "../src/CollateralVault.sol";
import "../src/mocks/MockUSD.sol";
import "../src/mocks/MockOracle.sol";

/// @notice Forwards arbitrary calls so tests can act as a second trader.
/// @dev The test contract itself plays the role of trader #1 (and keeper).
contract Trader {
    function execute(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "Trader: forward failed");
        return ret;
    }
}

contract PerpMarketTest {
    MockUSD internal token;
    MockOracle internal oracle;
    CollateralVault internal vault;
    PerpMarket internal market;
    Trader internal bob;

    uint256 internal constant PRICE = 2000e18; // $2,000

    function setUp() public {
        token = new MockUSD();
        oracle = new MockOracle(PRICE);
        vault = new CollateralVault(address(token));
        market = new PerpMarket(address(vault), address(oracle));
        vault.setMarket(address(market));
        market.setKeeper(address(this)); // test contract acts as keeper

        bob = new Trader();
        token.mint(address(this), 100_000e18);
        token.mint(address(bob), 100_000e18);
        token.approve(address(vault), type(uint256).max);
        bob.execute(
            address(token),
            abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max)
        );
    }

    // -- collateral ----------------------------------------------------------

    function test_DepositWithdraw() public {
        market.deposit(1000e18);
        require(market.collateralOf(address(this)) == 1000e18, "deposit balance");
        market.withdraw(400e18);
        require(market.collateralOf(address(this)) == 600e18, "withdraw balance");
        require(token.balanceOf(address(this)) == 100_000e18 - 600e18, "tokens returned");
    }

    function test_WithdrawBlockedWhilePositionOpen() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5);
        try market.withdraw(100e18) {
            require(false, "withdraw should revert");
        } catch {}
    }

    // -- positions -----------------------------------------------------------

    function test_OpenLong_CloseProfit() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5); // 5x long @ $2,000
        oracle.setPrice(2200e18); // +10%
        market.closePosition();
        // PnL = 10% * 5000 = 500
        require(market.collateralOf(address(this)) == 1500e18, "long pnl wrong");
    }

    function test_OpenShort_CloseProfit() public {
        bob.execute(address(market), abi.encodeWithSignature("deposit(uint256)", 1000e18));
        bob.execute(
            address(market),
            abi.encodeWithSignature("openPosition(bool,uint256,uint256)", false, 4000e18, 4)
        );
        oracle.setPrice(1800e18); // -10%
        bob.execute(address(market), abi.encodeWithSignature("closePosition()"));
        // PnL = 10% * 4000 = 400
        require(market.collateralOf(address(bob)) == 1400e18, "short pnl wrong");
    }

    function test_RevertWhen_Undercollateralized() public {
        market.deposit(100e18);
        try market.openPosition(true, 5000e18, 10) {
            require(false, "should revert: margin 500 > collateral 100");
        } catch {}
    }

    function test_RevertWhen_BadLeverage() public {
        market.deposit(10_000e18);
        try market.openPosition(true, 5000e18, 0) {
            require(false, "should revert: zero leverage");
        } catch {}
        try market.openPosition(true, 5000e18, 21) {
            require(false, "should revert: leverage > max");
        } catch {}
    }

    // -- liquidation ---------------------------------------------------------

    function test_Liquidation() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5); // 5x long @ $2,000
        oracle.setPrice(1700e18); // -15% => unrealized -750, equity 250 < MM 312.5
        require(market.isLiquidatable(address(this)), "should be liquidatable");

        bob.execute(address(market), abi.encodeWithSignature("liquidate(address)", address(this)));

        // equity 250 => liquidator bonus 2% = 5, trader keeps 245
        require(market.collateralOf(address(this)) == 245e18, "post-liquidation balance");
        require(token.balanceOf(address(bob)) == 100_000e18 + 5e18, "liquidator bonus");
        PerpMarket.Position memory p = market.getPosition(address(this));
        require(p.sizeUsd == 0, "position not closed");
    }

    function test_NotLiquidatableWhenHealthy() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5);
        oracle.setPrice(1950e18); // -2.5% => equity 875 > MM 312.5
        require(!market.isLiquidatable(address(this)), "should be healthy");
        try market.liquidate(address(this)) {
            require(false, "liquidate should revert");
        } catch {}
    }

    // -- funding -------------------------------------------------------------

    function test_FundingAccrual() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5); // this = long
        bob.execute(address(market), abi.encodeWithSignature("deposit(uint256)", 1000e18));
        bob.execute(
            address(market),
            abi.encodeWithSignature("openPosition(bool,uint256,uint256)", false, 5000e18, 5)
        ); // bob = short

        market.accrueFunding(100, 1 days); // +100 bps/day => longs pay shorts

        PerpMarket.Position memory pl = market.getPosition(address(this));
        PerpMarket.Position memory ps = market.getPosition(address(bob));
        require(pl.fundingPaid == 50e18, "long fundingPaid");
        require(ps.fundingPaid == -50e18, "short fundingPaid");
        require(market.equity(address(this)) == 950e18, "long equity");
        require(market.equity(address(bob)) == 1050e18, "short equity");
    }

    function test_CloseAfterFunding() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5);
        market.accrueFunding(100, 1 days); // long pays 50, price unchanged
        market.closePosition();
        require(market.collateralOf(address(this)) == 950e18, "funding deducted on close");
    }

    function test_OnlyKeeperCanAccrueFunding() public {
        market.deposit(1000e18);
        market.openPosition(true, 5000e18, 5);
        try bob.execute(
            address(market), abi.encodeWithSignature("accrueFunding(int256,uint256)", int256(100), 1 days)
        ) {
            require(false, "non-keeper accrue should revert");
        } catch {}
    }
}
