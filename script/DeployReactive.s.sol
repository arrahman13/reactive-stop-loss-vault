// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { StopLossReactive } from "../src/StopLossReactive.sol";

interface IExtendedPayable {
    function depositTo(address contract_) external payable;
    function reserves(address contract_) external view returns (uint256);
}

/// @notice Step 2 (Reactive Lasna): deploy the reactive contract, funded with
///         lREACT both as contract balance (2 lREACT, spent via pay()) and as
///         system-contract reserves (3 lREACT, spent first).
///         Env: FEED = MockPriceFeed address on Base Sepolia.
///         Run: forge script script/DeployReactive.s.sol --rpc-url $LASNA_RPC \
///              --broadcast (key via DEPLOYER_PK env)
contract DeployReactive is Script {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;

    function run() external {
        address feed = vm.envAddress("FEED");
        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        StopLossReactive reactive = new StopLossReactive{ value: 2 ether }(feed);
        IExtendedPayable(SYSTEM).depositTo{ value: 3 ether }(address(reactive));
        vm.stopBroadcast();

        console.log("REACTIVE:", address(reactive));
        console.log("RESERVES:", IExtendedPayable(SYSTEM).reserves(address(reactive)));
    }
}
