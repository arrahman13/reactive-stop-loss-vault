// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { StopLossReactive } from "../src/StopLossReactive.sol";

/// @notice Step 4 (Reactive Lasna): point the reactive contract at the vault
///         and the demo position, with a $90 stop-loss and $120 take-profit
///         around the $100 start price, and arm it.
///         Env: REACTIVE, VAULT, USER (position owner; the deployer).
contract ConfigureReactive is Script {
    function run() external {
        StopLossReactive reactive = StopLossReactive(payable(vm.envAddress("REACTIVE")));
        address vault = vm.envAddress("VAULT");
        address user = vm.envAddress("USER");

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        reactive.setTriggers(vault, user, 90 ether, 120 ether);
        vm.stopBroadcast();

        console.log("ARMED:", reactive.armed());
    }
}
