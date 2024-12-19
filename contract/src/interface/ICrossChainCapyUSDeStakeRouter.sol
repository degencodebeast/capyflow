// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ICrossChainCapyUSDeStakeRouter {
    /// @notice Initiates cross-chain funding of an Allo pool
    function fundAlloPoolCrossChain(
        uint256 _poolId,
        uint256 _amount,
        uint32 dstChainId,
        bytes calldata adapterParams
    ) external payable;

    /// @notice Callback for receiving OFT tokens
    function onOFTReceived(
        uint32 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata data
    ) external;
}