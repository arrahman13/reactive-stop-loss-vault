// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { GuardedVault } from "../src/GuardedVault.sol";
import { MockToken } from "../src/MockToken.sol";
import { MockPriceFeed } from "../src/MockPriceFeed.sol";

interface IExtendedPayable {
    function depositTo(address contract_) external payable;
    function reserves(address contract_) external view returns (uint256);
}

/// @notice Step 3 (Base Sepolia): deploy the vault (it needs the reactive
///         contract's address for callback authentication), fund its callback
///         reserves with the proxy, stock its USDQ payout reserve, and open
///         the demo position: the deployer deposits 100 AST at the feed price.
///         Env: AST, USDQ, FEED, REACTIVE.
contract DeployVault is Script {
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        MockToken asset = MockToken(vm.envAddress("AST"));
        MockToken quote = MockToken(vm.envAddress("USDQ"));
        MockPriceFeed feed = MockPriceFeed(vm.envAddress("FEED"));
        address reactive = vm.envAddress("REACTIVE");
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        GuardedVault vault = new GuardedVault{ value: 0.005 ether }(
            IPayable(payable(BASE_SEPOLIA_PROXY)), reactive, asset, quote
        );
        IExtendedPayable(BASE_SEPOLIA_PROXY).depositTo{ value: 0.01 ether }(address(vault));

        quote.mint(address(vault), 1_000_000 ether); // payout reserve
        asset.mint(deployer, 1_000 ether);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, feed.price());
        vm.stopBroadcast();

        console.log("VAULT:", address(vault));
        console.log("VAULT_RESERVES:", IExtendedPayable(BASE_SEPOLIA_PROXY).reserves(address(vault)));
    }
}
