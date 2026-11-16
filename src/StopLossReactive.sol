// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title StopLossReactive
/// @notice Reactive contract on Reactive Lasna. It subscribes to
///         `PriceUpdated` events from a price feed on Base Sepolia and, the
///         moment the price crosses the configured stop-loss or take-profit
///         for a watched vault position, requests a callback that makes the
///         vault exit the position into a stable token. With Omni's ~1s
///         blocks and instant finality, the whole loop — price event on Base
///         Sepolia, decision here, execution back on Base Sepolia — closes
///         in seconds, with no keeper or off-chain bot in the loop.
/// @dev The decision logic lives here, on purpose: the destination vault is a
///      dumb executor that only authenticates and swaps. Thresholds, arming
///      and one-shot semantics are all reactive-side state.
contract StopLossReactive is AbstractReactive {
    uint256 public constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    uint256 public constant DESTINATION_CHAIN_ID = 84532; // Base Sepolia
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    uint8 public constant KIND_STOP_LOSS = 1;
    uint8 public constant KIND_TAKE_PROFIT = 2;

    // keccak256("PriceUpdated(uint256)")
    uint256 public constant PRICE_UPDATED_TOPIC = 0x66cbca4f3c64fecf1dcb9ce094abcf7f68c3450a1d4e3a8e917dd621edb4ebe0;

    address public immutable owner;
    address public immutable feed;

    address public vault; // destination contract (GuardedVault) on Base Sepolia
    address public positionOwner; // whose position the vault should exit
    uint256 public stopLossPrice; // trigger at or below (18 decimals)
    uint256 public takeProfitPrice; // trigger at or above (18 decimals)
    bool public armed;

    uint256 public lastPrice;
    uint256 public reactionCount;
    uint256 public triggerCount;
    uint8 public lastTriggerKind;
    uint256 public lastTriggerPrice;

    event TriggersSet(address vault, address positionOwner, uint256 stopLossPrice, uint256 takeProfitPrice);
    event Triggered(uint8 indexed kind, uint256 price, address indexed user);
    event PriceSeen(uint256 price);

    constructor(address feed_) payable {
        owner = msg.sender;
        feed = feed_;
        SYSTEM.subscribe(
            ORIGIN_CHAIN_ID, feed_, PRICE_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "StopLossReactive: not owner");
        _;
    }

    /// @notice Point the contract at a vault + position and (re-)arm it.
    ///         Called again to re-arm after a trigger has fired.
    function setTriggers(address vault_, address positionOwner_, uint256 stopLossPrice_, uint256 takeProfitPrice_)
        external
        onlyOwner
    {
        require(vault_ != address(0), "StopLossReactive: zero vault");
        require(stopLossPrice_ < takeProfitPrice_, "StopLossReactive: stop >= take-profit");
        vault = vault_;
        positionOwner = positionOwner_;
        stopLossPrice = stopLossPrice_;
        takeProfitPrice = takeProfitPrice_;
        armed = true;
        emit TriggersSet(vault_, positionOwner_, stopLossPrice_, takeProfitPrice_);
    }

    function disarm() external onlyOwner {
        armed = false;
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // Defensive re-check of the subscription criteria; unmatched logs
        // fall through silently (reverting would still be billed).
        if (
            log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != feed
                || log_.topic0 != PRICE_UPDATED_TOPIC
        ) {
            return;
        }

        uint256 price = abi.decode(log_.data, (uint256));
        lastPrice = price;
        reactionCount++;
        emit PriceSeen(price);

        if (!armed || vault == address(0)) {
            return;
        }

        uint8 kind = 0;
        if (price <= stopLossPrice) {
            kind = KIND_STOP_LOSS;
        } else if (price >= takeProfitPrice) {
            kind = KIND_TAKE_PROFIT;
        }
        if (kind == 0) {
            return;
        }

        // One-shot: disarm before requesting the callback so a burst of
        // price updates cannot drain fees with duplicate exits.
        armed = false;
        triggerCount++;
        lastTriggerKind = kind;
        lastTriggerPrice = price;
        emit Triggered(kind, price, positionOwner);

        // First payload argument is reserved: the network overwrites it with
        // this contract's address so the vault can authenticate the sender.
        bytes memory payload = abi.encodeWithSignature(
            "executeExit(address,address,uint8,uint256)", address(0), positionOwner, kind, price
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DESTINATION_CHAIN_ID,
                recipient: vault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    /// @notice Settles outstanding system-contract debt from this contract's
    ///         own lREACT balance.
    function coverDebt() external {
        _coverDebt();
    }
}
