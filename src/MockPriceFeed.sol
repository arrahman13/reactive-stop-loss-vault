// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockPriceFeed
/// @notice Stand-in for a price oracle on the origin chain (Base Sepolia).
///         The owner pushes a new price with `setPrice`, which emits
///         `PriceUpdated` — the event the reactive contract subscribes to.
///         Prices are USD per AST with 18 decimals (100e18 = $100).
contract MockPriceFeed {
    address public immutable owner;
    uint256 public price;

    event PriceUpdated(uint256 price);

    constructor(uint256 initialPrice_) {
        owner = msg.sender;
        price = initialPrice_;
    }

    function setPrice(uint256 price_) external {
        require(msg.sender == owner, "MockPriceFeed: not owner");
        price = price_;
        emit PriceUpdated(price_);
    }
}
