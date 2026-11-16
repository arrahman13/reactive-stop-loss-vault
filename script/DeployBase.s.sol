// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";

/// @notice Step 1 (Base Sepolia): deploy the two demo tokens and the price feed.
///         Run: forge script script/DeployBase.s.sol --rpc-url $BASE_SEPOLIA_RPC \
///              --broadcast (key via DEPLOYER_PK env)
contract DeployBase is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        MockToken asset = new MockToken("Asset Token", "AST");
        MockToken quote = new MockToken("USD Quote", "USDQ");
        MockPriceFeed feed = new MockPriceFeed(100 ether); // starts at $100
        vm.stopBroadcast();

        console.log("AST:", address(asset));
        console.log("USDQ:", address(quote));
        console.log("FEED:", address(feed));
    }
}
