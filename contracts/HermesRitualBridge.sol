// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HermesRitualBridge
/// @notice Locks tokens on the source chain and emits events for the off-chain
///         relayer to mint/release on the destination chain.
contract HermesRitualBridge {
    address public owner;

    event Locked(
        address indexed sender,
        uint256 indexed destChainId,
        bytes destRecipient,
        uint256 amount,
        uint256 nonce
    );

    uint256 public nonce;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Lock native value to be bridged to `destChainId`.
    function lock(uint256 destChainId, bytes calldata destRecipient) external payable {
        require(msg.value > 0, "zero amount");
        emit Locked(msg.sender, destChainId, destRecipient, msg.value, nonce++);
    }
}
