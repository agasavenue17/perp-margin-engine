// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockOracle — settable price feed for local testing (price scaled by 1e18).
/// @notice Stands in for a real oracle (e.g. Chainlink / Pyth) so the margin engine can be
///         exercised without a live network. Never use in production.
contract MockOracle {
    address public owner;
    uint256 private _price; // 1e18 == $1.00

    event PriceUpdated(uint256 price);

    constructor(uint256 initialPrice) {
        owner = msg.sender;
        _price = initialPrice;
    }

    function setPrice(uint256 price) external {
        require(msg.sender == owner, "MockOracle: only owner");
        require(price > 0, "MockOracle: zero price");
        _price = price;
        emit PriceUpdated(price);
    }

    function latestPrice() external view returns (uint256) {
        return _price;
    }
}
