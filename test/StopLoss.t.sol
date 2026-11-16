// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";
import { GuardedVault } from "../src/GuardedVault.sol";
import { StopLossReactive } from "../src/StopLossReactive.sol";
import { MockSystemContract } from "./MockSystemContract.sol";
import { MockCallbackProxy } from "./MockCallbackProxy.sol";

contract StopLossTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant BASE_SEPOLIA = 84532;

    MockSystemContract internal system;
    MockCallbackProxy internal proxy;
    MockToken internal asset;
    MockToken internal quote;
    MockPriceFeed internal feed;
    StopLossReactive internal reactive;
    GuardedVault internal vault;
    address internal user;
    uint256 internal priceTopic;

    function setUp() public {
        // Point AbstractReactive's hardcoded SYSTEM constant at a mock.
        MockSystemContract mockImpl = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(mockImpl).code);
        system = MockSystemContract(SYSTEM_ADDR);

        asset = new MockToken("Asset Token", "AST");
        quote = new MockToken("USD Quote", "USDQ");
        feed = new MockPriceFeed(100 ether);
        reactive = new StopLossReactive{ value: 1 ether }(address(feed));
        proxy = new MockCallbackProxy();
        vault = new GuardedVault{ value: 1 ether }(
            IPayable(payable(address(proxy))), address(reactive), asset, quote
        );

        user = makeAddr("user");
        asset.mint(user, 1_000 ether);
        quote.mint(address(vault), 1_000_000 ether); // vault's payout reserve
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(user);
        vault.deposit(100 ether, 100 ether);

        reactive.setTriggers(address(vault), user, 90 ether, 120 ether);
        priceTopic = reactive.PRICE_UPDATED_TOPIC();
    }

    // ---- helpers ----

    function _priceLog(uint256 price_) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: address(feed),
            topic0: priceTopic,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(price_),
            blockNumber: 1,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _react(uint256 price_) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(_priceLog(price_));
    }

    function _deliverLastCallback() internal {
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = system.lastCallback();
        assertEq(cfg.chainId, BASE_SEPOLIA);
        assertEq(cfg.recipient, address(vault));
        // Strip the 4-byte selector and decode the arguments; the first one
        // is the placeholder the proxy overwrites with the reactive address.
        bytes memory args = new bytes(cfg.payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = cfg.payload[i + 4];
        }
        (address placeholder, address user_, uint8 kind_, uint256 price_) =
            abi.decode(args, (address, address, uint8, uint256));
        assertEq(placeholder, address(0));
        vm.prank(address(proxy));
        vault.executeExit(address(reactive), user_, kind_, price_);
    }

    // ---- tests ----

    function testConstructorSubscribesToFeed() public view {
        assertEq(system.subscriptionCount(), 1);
    }

    function testFeedEmitsPriceUpdated() public {
        vm.expectEmit(false, false, false, true, address(feed));
        emit MockPriceFeed.PriceUpdated(95 ether);
        feed.setPrice(95 ether);
        assertEq(feed.price(), 95 ether);
    }

    function testReactInRangeDoesNothing() public {
        _react(95 ether);
        assertEq(reactive.lastPrice(), 95 ether);
        assertEq(reactive.reactionCount(), 1);
        assertEq(system.callbackCount(), 0);
        assertTrue(reactive.armed());
    }

    function testStopLossFullLoop() public {
        _react(85 ether); // below the 90 stop-loss
        assertEq(system.callbackCount(), 1);
        assertEq(reactive.triggerCount(), 1);
        assertEq(reactive.lastTriggerKind(), reactive.KIND_STOP_LOSS());
        assertFalse(reactive.armed()); // one-shot

        _deliverLastCallback();

        (uint256 amount,) = vault.positions(user);
        assertEq(amount, 0);
        assertEq(quote.balanceOf(user), 100 ether * 85); // 100 AST * $85
        assertEq(asset.balanceOf(address(vault)), 100 ether); // asset stays in the vault
    }

    function testTakeProfitFullLoop() public {
        _react(125 ether); // above the 120 take-profit
        assertEq(reactive.lastTriggerKind(), reactive.KIND_TAKE_PROFIT());
        _deliverLastCallback();
        assertEq(quote.balanceOf(user), 100 ether * 125);
    }

    function testTriggerIsOneShot() public {
        _react(85 ether);
        _react(80 ether); // still below stop, but disarmed now
        assertEq(system.callbackCount(), 1);
        // Owner can re-arm for a new position.
        reactive.setTriggers(address(vault), user, 90 ether, 120 ether);
        _react(80 ether);
        assertEq(system.callbackCount(), 2);
    }

    function testReactRejectsNonSystemCaller() public {
        vm.expectRevert();
        reactive.react(_priceLog(85 ether));
    }

    function testUnmatchedLogIsIgnored() public {
        IReactive.LogRecord memory log_ = _priceLog(10 ether);
        log_.topic0 = 0xdeadbeef;
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
        assertEq(reactive.reactionCount(), 0);
        assertEq(system.callbackCount(), 0);
    }

    function testVaultRejectsDirectCall() public {
        vm.prank(user);
        vm.expectRevert();
        vault.executeExit(address(reactive), user, 1, 85 ether);
    }

    function testVaultRejectsWrongReactiveSender() public {
        vm.prank(address(proxy));
        vm.expectRevert();
        vault.executeExit(address(0xBADC0DE), user, 1, 85 ether);
    }

    function testExitWithNoPositionIsGraceful() public {
        address stranger = makeAddr("stranger");
        vm.prank(address(proxy));
        vault.executeExit(address(reactive), stranger, 1, 85 ether); // must not revert
    }

    function testManualWithdraw() public {
        vm.prank(user);
        vault.withdrawPosition();
        assertEq(asset.balanceOf(user), 1_000 ether);
    }
}
