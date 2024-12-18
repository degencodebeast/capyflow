// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice OFTAdapter uses a deployed ERC-20 token and safeERC20 to interact with the OFTCore contract.

contract CapyUSDeOFTAdapter is OFTAdapter {
    constructor(
        address _usdeToken,      // Original USDe token
        address _lzEndpoint,     // LayerZero endpoint for the chain
        address _owner          // Owner of the adapter
    ) OFTAdapter(_usdeToken, _lzEndpoint, _owner) {}
}