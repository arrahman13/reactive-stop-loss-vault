// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockSystemContract
/// @notice Test double for the Reactive system contract. Tests etch this code
///         at the real SYSTEM address (0x8888...8888) so AbstractReactive's
///         hardcoded constant points at it. It records subscriptions and
///         callback requests instead of delivering them, and never charges.
contract MockSystemContract {
    struct Subscription {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
    }

    Subscription[] public subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0[] public callbackRequests;

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256, // topic1_
        uint256, // topic2_
        uint256 // topic3_
    ) external {
        subscriptions.push(Subscription({ chainId: chainId_, contractAddress: contract_, topic0: topic0_ }));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests.push(config_);
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbackRequests.length;
    }

    function lastCallback() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return callbackRequests[callbackRequests.length - 1];
    }

    // IPayable surface AbstractPayer relies on.
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    function depositTo(address) external payable { }
}
