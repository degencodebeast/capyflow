// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ICapyUSDeOFTAdapter} from "./interface/ICapyUSDeOFTAdapter.sol";
import {ICapySUSDeOFTAdapter} from "./interface/ICapySUSDeOFTAdapter.sol";


/// @title CrossChainCapyUSDeStakeRouter
/// @notice Router contract for staking USDe and funding Allo pools with sUSDe
contract CrossChainCapyUSDeStakeRouter is ReentrancyGuard {
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

    /// @notice Thrown when caller is invalid
    error INVALID_CALLER();

    /// @notice Thrown when adapter is invalid
    error INVALID_ADAPTER();

    /// @notice Thrown when cross-chain transfer fails
    error CROSS_CHAIN_TRANSFER_FAILED();

    // ====================================
    // =========== Events ================
    // ====================================
    event CrossChainUSDeReceived(
        address indexed strategy,
        uint256 indexed poolId,
        uint256 amount,
        uint32 srcChainId
    );
    event USDeStaked(uint256 amount, uint256 sUsdeReceived);
    event CrossChainSUSDeInitiated(
        address indexed strategy,
        uint256 indexed poolId,
        uint256 amount,
        uint32 dstChainId
    );

    // ====================================
    // =========== Storage ===============
    // ====================================

    IERC20 public immutable usde;
    IERC20 public immutable sUsde;
    address public immutable alloContract;
    // ICapyUSDeOFTAdapter public immutable oftAdapter;
    ICapyUSDeOFTAdapter public immutable usdeOFTAdapter;
    ICapySUSDeOFTAdapter public immutable sUsdeOFTAdapter;


    constructor(
        address _usde,
        address _sUsde,
        address _alloContract,
        address _usdeOFTAdapter,
        address _sUsdeOFTAdapter
    ) {
        usde = IERC20(_usde);
        sUsde = IERC20(_sUsde);
        alloContract = _alloContract;
        usdeOFTAdapter = ICapyUSDeOFTAdapter(_usdeOFTAdapter);
        sUsdeOFTAdapter = ICapySUSDeOFTAdapter(_sUsdeOFTAdapter);

        // Approvals
        usde.approve(_usdeOFTAdapter, type(uint256).max);
        sUsde.approve(_sUsdeOFTAdapter, type(uint256).max);
    }

    
    /// @notice Step 2: Receive USDe from strategy and send via OFT
    /// @dev User must approve this contract to spend their USDe
    /// @param _poolId ID of the pool in Allo
    /// @param _amount The amount of USDe to stake and fund
    /// @param dstChainId The chain ID to send the USDe to
    /// @param adapterParams The adapter parameters for the OFT
    
    function fundAlloPoolCrossChain(
        uint256 _poolId,
        uint256 _amount,
        uint32 dstChainId,
        bytes calldata adapterParams
    ) external payable nonReentrant {
        if (_amount == 0) revert NOT_ENOUGH_FUNDS();

        // Transfer USDe from user
        // Transfer USDe from strategy to router
        usde.safeTransferFrom(msg.sender, address(this), _amount);

        // Send USDe cross-chain via OFT adapter
        try usdeOFTAdapter.sendFrom{value: msg.value}(
            address(this),    // from
            dstChainId,      // destination chain
            abi.encode(msg.sender, _poolId, _amount), // strategy, poolId, amount
            _amount,         // amount
            payable(msg.sender), // refund address
            address(0),      // zero address
            adapterParams    // adapter parameters
        ) {
            emit CrossChainUSDeReceived(msg.sender, _poolId, _amount, dstChainId);
        } catch {
            // Refund USDe if cross-chain transfer fails
            usde.safeTransfer(msg.sender, _amount);
            revert CROSS_CHAIN_TRANSFER_FAILED();
        }
    }

    /// @notice Step 3: Receive USDe on destination chain and stake for sUSDe
    function onOFTReceived(
        uint32 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata data
    ) external nonReentrant {
        if (msg.sender != address(usdeOFTAdapter)) revert INVALID_CALLER();
        
        (address strategy, uint256 poolId, uint256 amount) = abi.decode(
            data,
            (address, uint256, uint256)
        );

        // Stake USDe for sUSDe
        uint256 sUsdeReceived = _stakeUSDe(amount);
        emit USDeStaked(amount, sUsdeReceived);

        // Step 4: Send sUSDe back via OFT
        _sendSUSDeBack(strategy, poolId, sUsdeReceived, srcChainId);
    }

     /// @notice Internal function to stake USDe for sUSDe
    function _stakeUSDe(uint256 amount) internal returns (uint256) {
        usde.approve(address(sUsde), amount);
        
        uint256 preBalance = sUsde.balanceOf(address(this));
        
        (bool success, ) = address(sUsde).call(
            abi.encodeWithSignature(
                "deposit(uint256,address)",
                amount,
                address(this)
            )
        );
        if (!success) revert DEPOSIT_FAILED();

        uint256 postBalance = sUsde.balanceOf(address(this));
        return postBalance - preBalance;
    }

       /// @notice Internal function to send sUSDe back to source chain
    function _sendSUSDeBack(
        address strategy,
        uint256 poolId,
        uint256 amount,
        uint32 srcChainId
    ) internal {
        try sUsdeOFTAdapter.sendFrom(
            address(this),
            srcChainId,
            abi.encode(strategy, poolId, amount),
            amount,
            payable(address(this)),
            address(0),
            "" // Default adapter params
        ) {
            emit CrossChainSUSDeInitiated(strategy, poolId, amount, srcChainId);
        } catch {
            revert CROSS_CHAIN_TRANSFER_FAILED();
        }
    }


    // // Receive cross-chain USDe and stake
    // function onOFTReceived(
    //     uint32 srcChainId,
    //     bytes calldata srcAddress,
    //     uint64 nonce,
    //     bytes calldata data
    // ) external {
    //     require(msg.sender == address(usdeOFTAdapter), "Only USDe OFT Adapter");
        
    //     (address user, uint256 poolId) = abi.decode(data, (address, uint256));
    //     uint256 amount = usde.balanceOf(address(this));
        
    //     // Stake USDe to get sUSDe
    //     _stakeAndFund(poolId, amount);
    // }

    // function _stakeAndFund(uint256 _poolId, uint256 _amount) internal {
    //     // Original staking logic
    //     usde.approve(address(sUsde), _amount);
    //     (bool success, ) = address(sUsde).call(
    //         abi.encodeWithSignature(
    //             "deposit(uint256,address)",
    //             _amount,
    //             address(this)
    //         )
    //     );
    //     if (!success) revert DEPOSIT_FAILED();

    //     uint256 sUsdeReceived = sUsde.balanceOf(address(this));

    //     // Fund the pool
    //     (success,) = alloContract.call(
    //         abi.encodeWithSignature(
    //             "fundPool(uint256,uint256)", 
    //             _poolId,
    //             sUsdeReceived
    //         )
    //     );
    //     if (!success) revert FUND_POOL_FAILED();
    // }
}

// OFT Adapter allows an existing token to expand to any supported chain as a native token with a unified global supply, inheriting all the features of the OFT Standard. This works as an intermediary contract that handles sending and receiving tokens that have already been deployed. Read more [here](https://docs.layerzero.network/v2/developers/evm/oft/adapter).

// Ideally, when you want to convert an existing ERC20 token with its current fixed supply into an Omnichain token, you can use the OFTAdapter as a wrapper around that ERC20.

// There are several ways to go about it since the base code of OFTAdapter keeps contract logic implementation up to the developer. Eg., the Adapter could be implemented in such a way that the original ERC20 is locked inside the Adapter on chain A and the OFT is minted on chain B.


// ✅ Trust owner funds strategy through stake router (owner initiates funding)
// Implemented in CapyTrustStrategy.fundStrategyFromSourceChain()

// ✅ OFT USDe sent to Capy USDe Stake Router (Strategy approves and router sends USDe cross-chain:)
// Handled by CrossChainCapyUSDeStakeRouter.fundAlloPoolCrossChain()
// Uses CapyUSDeOFTAdapter for cross-chain transfer

// ✅ Router stakes USDe for sUSDe ( Router receives USDe on destination chain and stakes:)
// Implemented in CrossChainCapyUSDeStakeRouter.onOFTReceived() and _stakeUSDe()

// ✅ Router sends back OFT sUSDe (Router sends sUSDe back)
// Handled by CrossChainCapyUSDeStakeRouter._sendSUSDeBack()
// Uses CapySUSDeOFTAdapter for cross-chain transfer

// ✅ Strategy receives sUSDe and funds the pool (Strategy receives sUSDe and funds pool:)
// Implemented in CapyTrustStrategy.onSUSDeReceived()
// Uses BaseStrategy's _fundPool() to complete the funding