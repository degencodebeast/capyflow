// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


interface ICapyUSDeOFTAdapter {
    /// @notice Sends USDe tokens from this chain to another chain
    /// @param _from Address sending the tokens
    /// @param _dstChainId Destination chain ID
    /// @param _data Encoded data (strategy address, poolId, amount)
    /// @param _amount Amount of tokens to send
    /// @param _refundAddress Address to refund excess gas
    /// @param _zroPaymentAddress Address for zero payment
    /// @param _adapterParams Additional parameters for the adapter
    function sendFrom(
        address _from,
        uint32 _dstChainId,
        bytes calldata _data,
        uint256 _amount,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;

    /// @notice Estimates the fee for sending tokens cross-chain
    function estimateSendFee(
        uint32 dstChainId,
        bytes calldata data,
        uint256 amount,
        bytes calldata adapterParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);
}


