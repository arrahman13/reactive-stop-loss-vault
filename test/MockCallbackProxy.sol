// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title MockCallbackProxy
/// @notice Test double for a destination chain's callback proxy. Only the
///         IPayable surface AbstractCallback relies on is implemented; tests
///         deliver callbacks by impersonating this contract's address.
contract MockCallbackProxy {
    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    function depositTo(address) external payable { }
}
