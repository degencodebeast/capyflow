// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ICapyUSDeOFTAdapter} from "./interfaces/ICapyUSDeOFTAdapter.sol";

/// @title CapyUSDeStakeRouter
/// @notice Router contract for staking USDe and funding Allo pools with sUSDe
contract CapyUSDeStakeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // =========== Errors =================
    // ====================================

    /// @notice Thrown when amount is 0 or insufficient
    error NOT_ENOUGH_FUNDS();

    /// @notice Thrown when deposit fails
    error DEPOSIT_FAILED();

    /// @notice Thrown when funding pool fails
    error FUND_POOL_FAILED();

    // ====================================
    // =========== Storage ===============
    // ====================================

    IERC20 public immutable usde;
    IERC20 public immutable sUsde;
    address public immutable alloContract;
    ICapyUSDeOFTAdapter public immutable oftAdapter;

    constructor(
        address _usde,
        address _sUsde,
        address _alloContract,
        address _oftAdapter
    ) {
        usde = IERC20(_usde);
        sUsde = IERC20(_sUsde);
        alloContract = _alloContract;
        oftAdapter = ICapyUSDeOFTAdapter(_oftAdapter);

        // Approvals
        usde.approve(_oftAdapter, type(uint256).max);
        sUsde.approve(_alloContract, type(uint256).max);
    }

    /// @notice Fund an Allo pool by first staking USDe to get sUSDe
    /// @dev User must approve this contract to spend their USDe
    /// @param _poolId ID of the pool in Allo
    /// @param _amount The amount of USDe to stake and fund
    function fundAlloPoolCrossChain(
        uint256 _poolId,
        uint256 _amount,
        uint32 dstChainId,
        bytes calldata adapterParams
    ) external payable nonReentrant {
        if (_amount == 0) revert NOT_ENOUGH_FUNDS();

        // Transfer USDe from user
        usde.safeTransferFrom(msg.sender, address(this), _amount);

        // Convert to OFT USDe and send cross-chain
        oftAdapter.sendFrom{value: msg.value}(
            address(this),    // from
            dstChainId,      // destination chain
            abi.encode(msg.sender, _poolId), // receiver data
            _amount,         // amount
            payable(msg.sender), // refund address
            address(0),      // zero address
            adapterParams    // adapter parameters
        );
    }

    // Receive cross-chain USDe and stake
    function onOFTReceived(
        uint32 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata data
    ) external {
        require(msg.sender == address(oftAdapter), "Only OFT Adapter");
        
        (address user, uint256 poolId) = abi.decode(data, (address, uint256));
        uint256 amount = usde.balanceOf(address(this));
        
        // Stake USDe to get sUSDe
        _stakeAndFund(poolId, amount);
    }

    function _stakeAndFund(uint256 _poolId, uint256 _amount) internal {
        // Original staking logic
        usde.approve(address(sUsde), _amount);
        (bool success, ) = address(sUsde).call(
            abi.encodeWithSignature(
                "deposit(uint256,address)",
                _amount,
                address(this)
            )
        );
        if (!success) revert DEPOSIT_FAILED();

        uint256 sUsdeReceived = sUsde.balanceOf(address(this));

        // Fund the pool
        (success,) = alloContract.call(
            abi.encodeWithSignature(
                "fundPool(uint256,uint256)", 
                _poolId,
                sUsdeReceived
            )
        );
        if (!success) revert FUND_POOL_FAILED();
    }
}

// OFT Adapter allows an existing token to expand to any supported chain as a native token with a unified global supply, inheriting all the features of the OFT Standard. This works as an intermediary contract that handles sending and receiving tokens that have already been deployed. Read more [here](https://docs.layerzero.network/v2/developers/evm/oft/adapter).

// Ideally, when you want to convert an existing ERC20 token with its current fixed supply into an Omnichain token, you can use the OFTAdapter as a wrapper around that ERC20.

// There are several ways to go about it since the base code of OFTAdapter keeps contract logic implementation up to the developer. Eg., the Adapter could be implemented in such a way that the original ERC20 is locked inside the Adapter on chain A and the OFT is minted on chain B.