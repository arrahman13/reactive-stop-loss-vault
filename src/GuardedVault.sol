// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { MockToken } from "./MockToken.sol";

/// @title GuardedVault
/// @notice Destination-side contract on Base Sepolia. Users park the volatile
///         asset (AST) here as a position; the vault also holds a reserve of
///         the stable token (USDQ). When the reactive contract on Reactive
///         Lasna decides a stop-loss or take-profit has triggered, it requests
///         a callback to `executeExit`, and the vault atomically swaps the
///         user's whole position into USDQ at the trigger price and pays the
///         user out — no keeper, no bot, no user transaction needed.
/// @dev Callback authentication follows the Reactive Omni pattern: the call
///      must come from the chain's callback proxy (`onlyServiceProvider`) and
///      the first payload argument — overwritten by the proxy with the
///      requesting reactive contract's address — must match the authorized
///      reactive contract (`onlyCallbackSender`).
contract GuardedVault is AbstractCallback {
    uint8 public constant KIND_STOP_LOSS = 1;
    uint8 public constant KIND_TAKE_PROFIT = 2;

    MockToken public immutable asset;
    MockToken public immutable quote;

    struct Position {
        uint256 amount; // AST held for the user
        uint256 entryPrice; // feed price when the position was opened
    }

    mapping(address => Position) public positions;

    event PositionOpened(address indexed user, uint256 amount, uint256 entryPrice);
    event PositionExited(
        address indexed user, uint8 indexed kind, uint256 price, uint256 assetAmount, uint256 quoteOut
    );
    event ExitSkipped(address indexed user, uint8 indexed kind, uint256 price);
    event PositionWithdrawn(address indexed user, uint256 amount);

    constructor(IPayable callbackProxy_, address reactive_, MockToken asset_, MockToken quote_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        asset = asset_;
        quote = quote_;
    }

    /// @notice Open a position by depositing AST. One open position per user.
    function deposit(uint256 amount_, uint256 entryPrice_) external {
        require(amount_ > 0, "GuardedVault: zero amount");
        require(positions[msg.sender].amount == 0, "GuardedVault: position already open");
        require(asset.transferFrom(msg.sender, address(this), amount_), "GuardedVault: transfer failed");
        positions[msg.sender] = Position({ amount: amount_, entryPrice: entryPrice_ });
        emit PositionOpened(msg.sender, amount_, entryPrice_);
    }

    /// @notice Manually close a position and take the AST back (no swap).
    function withdrawPosition() external {
        uint256 amount = positions[msg.sender].amount;
        require(amount > 0, "GuardedVault: no position");
        positions[msg.sender].amount = 0;
        require(asset.transfer(msg.sender, amount), "GuardedVault: transfer failed");
        emit PositionWithdrawn(msg.sender, amount);
    }

    /// @notice Callback entry point, called by the callback proxy on behalf of
    ///         the reactive contract when a trigger fires. Swaps the user's
    ///         whole position into USDQ at `price_` and pays the user.
    /// @param reactive_ Injected by the proxy: the reactive contract's address.
    /// @param user_     Whose position to exit.
    /// @param kind_     KIND_STOP_LOSS or KIND_TAKE_PROFIT.
    /// @param price_    Feed price at trigger time (18 decimals).
    function executeExit(address reactive_, address user_, uint8 kind_, uint256 price_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        uint256 amount = positions[user_].amount;
        if (amount == 0) {
            // Nothing to exit. Return gracefully instead of reverting so the
            // callback is recorded as delivered, not failed.
            emit ExitSkipped(user_, kind_, price_);
            return;
        }
        positions[user_].amount = 0;

        uint256 quoteOut = (amount * price_) / 1e18;
        uint256 reserve = quote.balanceOf(address(this));
        if (quoteOut > reserve) {
            quoteOut = reserve;
        }
        require(quote.transfer(user_, quoteOut), "GuardedVault: payout failed");
        emit PositionExited(user_, kind_, price_, amount, quoteOut);
    }

    /// @notice Settles outstanding callback-proxy debt from this contract's
    ///         own ETH balance. Open to anyone so a stalled vault can be
    ///         revived by a third party funding it.
    function coverDebt() external {
        _coverDebt();
    }
}
