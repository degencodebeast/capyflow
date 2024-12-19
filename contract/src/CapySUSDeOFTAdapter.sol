// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract CapySUSDeOFTAdapter is OFTAdapter {
    constructor(
        address _susdeToken,     // Original sUSDe token
        address _lzEndpoint,     // LayerZero endpoint for the chain
        address _owner          // Owner of the adapter
    ) OFTAdapter(_susdeToken, _lzEndpoint, _owner) {}
}