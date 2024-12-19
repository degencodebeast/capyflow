// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "allo-v2/strategies/BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {CrossChainCapyUSDeStakeRouter} from "./CrossChainCapyUSDeStakeRouter.sol";
// import {ICapyUSDeOFTAdapter} from "./interface/ICapyUSDeOFTAdapter.sol";
// import {ICapySUSDeOFTAdapter} from "./interface/ICapySUSDeOFTAdapter.sol";

interface ICapyCore {
    function handleDistribution(
        uint256 poolId,
        IERC20 token,
        address[] memory recipients,
        uint256[] memory allocations,
        uint32 duration,
        address[] memory whitelistedCollectors
    ) external;
}

/// @title CapyCrossChainTrustStrategy Contract
/// @notice This contract implements a custom strategy for distributing funds to recipients
/// @dev Inherits from BaseStrategy, OwnableUpgradeable, and ReentrancyGuard
contract CapyCrossChainTrustStrategy is
    BaseStrategy,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // ====================================
    // =========== Errors =================
    // ====================================
    error NOT_ENOUGH_FUNDS();
    error CROSS_CHAIN_FUNDING_FAILED();
    error INVALID_CALLER();

    ICapyCore internal immutable capyCore;
    IERC20 internal immutable usdeToken;
    IERC20 internal immutable susdeToken;
    CrossChainCapyUSDeStakeRouter public immutable crossChainStakeRouter;

    // ICapyUSDeOFTAdapter public immutable usdeOFTAdapter;
    // ICapySUSDeOFTAdapter public immutable sUsdeOFTAdapter;

    struct Recipient {
        address recipientAddress;
        uint256 allocation;
        Status status;
    }

    mapping(address => Recipient) public recipients;
    address[] public recipientList;
    address[] public whitelistedCollectors;

    // Timestamp management
    uint64 public registrationStartTime;
    uint64 public registrationEndTime;
    uint64 public allocationStartTime;
    uint64 public allocationEndTime;

    // Events
    event RecipientRegistered(
        address indexed recipientAddress,
        string name,
        string avatar,
        string bio
    );
    event AllocationUpdated(
        address indexed recipientAddress,
        uint256 newAllocation
    );
    event TimestampsUpdated(
        uint64 registrationStartTime,
        uint64 registrationEndTime,
        uint64 allocationStartTime,
        uint64 allocationEndTime
    );
    event BatchAllocationCompleted(
        uint256 allocationsCount,
        uint256 totalAllocated
    );
    event WhitelistedCollectorsUpdated(address[] newWhitelistedCollectors);
    event RecipientStatusUpdated(
        address indexed recipientAddress,
        Status status
    );
    event DistributionExecuted(
        address[] recipientIds,
        uint256[] allocations,
        uint32 duration
    );
    event CrossChainFundingInitiated(
        uint256 indexed poolId,
        uint256 amount,
        uint32 dstChainId
    );
    event CrossChainFundingCompleted(
        uint256 indexed poolId,
        uint256 amount
    );

    /// @notice Constructor to set the Allo contract, CapyCore, and token addresses
    /// @param _allo Address of the Allo contract
    /// @param _capyCore Address of the CapyCore contract
    /// @param _usdeToken Address of the USDE token used for distributions
    /// @param _susdeToken Address of the sUSDe token
    /// @param _crossChainStakeRouter Address of the CrossChainCapyUSDeStakeRouter contract
    constructor(
        address _allo,
        address _capyCore,
        address _usdeToken,
        address _susdeToken,
        address _crossChainStakeRouter
    ) BaseStrategy(_allo, "CapyTrustStrategy") {
        capyCore = ICapyCore(_capyCore);
        usdeToken = IERC20(_usdeToken);
        susdeToken = IERC20(_susdeToken);
        crossChainStakeRouter = CrossChainCapyUSDeStakeRouter(_crossChainStakeRouter);
    }

    /// @notice Initializes the strategy with factory specific parameters
    function factoryInitialize() external initializer {
        __Ownable_init();
    }

    /// @notice Initializes the strategy with pool-specific parameters
    /// @dev Overrides BaseStrategy's initialize function
    /// @param _poolId ID of the pool
    /// @param _data Encoded initialization parameters
    function initialize(
        uint256 _poolId,
        bytes memory _data
    ) external override reinitializer(2) {
        __BaseStrategy_init(_poolId);

        (
            uint64 _registrationStartTime,
            uint64 _registrationEndTime,
            uint64 _allocationStartTime,
            uint64 _allocationEndTime
        ) = abi.decode(_data, (uint64, uint64, uint64, uint64));

        _updatePoolTimestamps(
            _registrationStartTime,
            _registrationEndTime,
            _allocationStartTime,
            _allocationEndTime
        );
    }

    /// @notice Updates the pool timestamps
    /// @param _registrationStartTime New registration start time
    /// @param _registrationEndTime New registration end time
    /// @param _allocationStartTime New allocation start time
    /// @param _allocationEndTime New allocation end time
    function _updatePoolTimestamps(
        uint64 _registrationStartTime,
        uint64 _registrationEndTime,
        uint64 _allocationStartTime,
        uint64 _allocationEndTime
    ) internal {
        require(
            _registrationStartTime < _registrationEndTime,
            "Invalid registration times"
        );
        require(
            _allocationStartTime < _allocationEndTime,
            "Invalid allocation times"
        );
        require(
            _registrationEndTime <= _allocationStartTime,
            "Registration must end before allocation starts"
        );

        registrationStartTime = _registrationStartTime;
        registrationEndTime = _registrationEndTime;
        allocationStartTime = _allocationStartTime;
        allocationEndTime = _allocationEndTime;

        emit TimestampsUpdated(
            registrationStartTime,
            registrationEndTime,
            allocationStartTime,
            allocationEndTime
        );
    }

    /// @notice Registers a recipient
    /// @dev Overrides BaseStrategy's _registerRecipient function
    /// @param _data Encoded recipient data
    //  @param _sender Address of the sender
    /// @return recipientId The address of the registered recipient
    function _registerRecipient(
        bytes memory _data,
        address
    )
        internal
        override
        onlyActiveRegistration
        nonReentrant
        returns (address recipientId)
    {
        (
            address recipientAddress,
            string memory name,
            string memory avatar,
            string memory bio
        ) = abi.decode(_data, (address, string, string, string));

        require(
            recipients[recipientAddress].recipientAddress == address(0),
            "Recipient already registered"
        );

        recipients[recipientAddress] = Recipient({
            recipientAddress: recipientAddress,
            allocation: 0,
            status: Status.Pending
        });
        recipientList.push(recipientAddress);

        emit RecipientRegistered(recipientAddress, name, avatar, bio);
        emit RecipientStatusUpdated(recipientAddress, Status.Pending);

        return recipientAddress;
    }

    
    /// @notice Step 1: Trust owner initiates funding through the stake router
    function fundStrategyFromSourceChain(
        uint256 amount,
        uint32 dstChainId,
        bytes calldata adapterParams
    ) external payable onlyOwner nonReentrant {
        if (amount == 0) revert NOT_ENOUGH_FUNDS();

        // Transfer USDe from owner to strategy
        usdeToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // Approve USDe for stake router
        usdeToken.approve(address(crossChainStakeRouter), amount);
        
        // Initiate cross-chain funding through router
        try crossChainStakeRouter.fundAlloPoolCrossChain{value: msg.value}(
            poolId,  // from BaseStrategy
            amount,
            dstChainId,
            adapterParams
        ) {
            emit CrossChainFundingInitiated(poolId, amount, dstChainId);
        } catch {
            // Revert all state changes if cross-chain funding fails
            usdeToken.approve(address(crossChainStakeRouter), 0);
            revert CROSS_CHAIN_FUNDING_FAILED();
        }
    }

    
    /// @notice Step 5: Strategy receives sUSDe back and funds the pool
    function onSUSDeReceived(
        uint32 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata data
    ) external nonReentrant {
        // Only the stake router should be calling this
        if (msg.sender != address(crossChainStakeRouter)) revert INVALID_CALLER();
        
        (address strategy, uint256 _poolId, uint256 amount) = abi.decode(
            data,
            (address, uint256, uint256)
        );
        
        // Validate the received data
        require(strategy == address(this), "Invalid strategy");
        require(_poolId == poolId, "Invalid pool");

        // Fund the Allo pool using the received sUSDe
        _fundPool(amount);

        emit CrossChainFundingCompleted(poolId, amount);
    }

    // Required override from BaseStrategy
    function _fundPool(uint256 _amount) internal {
        // Implementation from BaseStrategy
        allo.fundPool(poolId, _amount);
    }

    /// @notice Allocates funds to recipients
    /// @dev Overrides BaseStrategy's _allocate function
    /// @param _data Encoded allocation data
    /// @param _sender Address of the sender
    function _allocate(
        bytes memory _data,
        address _sender
    ) internal override onlyActiveAllocation onlyPoolManager(_sender) {
        (address[] memory recipientAddresses, uint256[] memory amounts) = abi
            .decode(_data, (address[], uint256[]));
        require(
            recipientAddresses.length == amounts.length,
            "Mismatched input arrays"
        );

        // First, validate all recipients
        for (uint256 i = 0; i < recipientAddresses.length; i++) {
            address recipientAddress = recipientAddresses[i];
            require(
                recipients[recipientAddress].recipientAddress != address(0),
                "Recipient not registered"
            );
            require(
                recipients[recipientAddress].status == Status.Accepted,
                "Recipient not accepted"
            );
        }

        // If all validations pass, perform the allocations
        uint256 totalAllocated = 0;
        for (uint256 i = 0; i < recipientAddresses.length; i++) {
            address recipientAddress = recipientAddresses[i];
            uint256 amount = amounts[i];

            recipients[recipientAddress].allocation = amount;
            totalAllocated += amount;

            emit AllocationUpdated(recipientAddress, amount);
        }

        require(totalAllocated > 0, "No funds allocated");

        emit BatchAllocationCompleted(
            recipientAddresses.length,
            totalAllocated
        );
    }

    /// @notice Distributes funds to recipients
    /// @dev Overrides BaseStrategy's _distribute function
    /// @param _recipientIds Array of recipient addresses
    /// @param _data Additional distribution data
    /// @custom:data '(uint256 duration)'
    /// @param _sender Address of the sender
    function _distribute(
        address[] memory _recipientIds,
        bytes memory _data,
        address _sender
    )
        internal
        override
        onlyAfterAllocation
        nonReentrant
        onlyPoolManager(_sender)
    {
        // Calculate duration
        uint32 duration = abi.decode(_data, (uint32));

        // Prepare allocation data
        uint256[] memory allocations = new uint256[](_recipientIds.length);
        uint256 totalAllocation = 0;
        for (uint256 i = 0; i < _recipientIds.length; i++) {
            allocations[i] = recipients[_recipientIds[i]].allocation;
            totalAllocation += allocations[i];
        }
        require(poolAmount >= totalAllocation, "Pool allocation funds too low");

        // TODO: maybe do a transfer approval instead
        // Transfer tokens to CapyCore
        usdeToken.safeTransfer(address(capyCore), totalAllocation);

        // Call handleDistribution on CapyCore
        capyCore.handleDistribution(
            poolId,
            usdeToken,
            _recipientIds,
            allocations,
            duration,
            whitelistedCollectors
        );

        emit DistributionExecuted(_recipientIds, allocations, duration);
    }

    /// @notice Returns the payout summary for a recipient
    /// @dev Overrides BaseStrategy's _getPayout function
    /// @param _recipientId Address of the recipient
    /// @return PayoutSummary struct with recipient address and allocated amount
    function _getPayout(
        address _recipientId,
        bytes memory
    ) internal view override returns (PayoutSummary memory) {
        return
            PayoutSummary({
                recipientAddress: _recipientId,
                amount: recipients[_recipientId].allocation
            });
    }

    /// @notice Returns the status of a recipient
    /// @dev Overrides BaseStrategy's _getRecipientStatus function
    /// @param _recipientId Address of the recipient
    /// @return Status of the recipient
    function _getRecipientStatus(
        address _recipientId
    ) internal view override returns (Status) {
        return recipients[_recipientId].status;
    }

    /// @notice Updates the status of a recipient
    /// @param _recipientAddress Address of the recipient
    /// @param _newStatus New status to set
    function updateRecipientStatus(
        address _recipientAddress,
        Status _newStatus
    ) external onlyPoolManager(msg.sender) {
        require(
            recipients[_recipientAddress].recipientAddress != address(0),
            "Recipient not registered"
        );
        recipients[_recipientAddress].status = _newStatus;
        emit RecipientStatusUpdated(_recipientAddress, _newStatus);
    }

    /// @notice Updates whitelisted collectors
    /// @param _newWhitelistedCollectors Address of the collector
    function updateWhitelistedCollectors(
        address[] memory _newWhitelistedCollectors
    ) external onlyPoolManager(msg.sender) {
        whitelistedCollectors = _newWhitelistedCollectors;
        emit WhitelistedCollectorsUpdated(_newWhitelistedCollectors);
    }

    /// @notice Updates the pool timestamps
    /// @param _registrationStartTime New registration start time
    /// @param _registrationEndTime New registration end time
    /// @param _allocationStartTime New allocation start time
    /// @param _allocationEndTime New allocation end time
    function updatePoolTimestamps(
        uint64 _registrationStartTime,
        uint64 _registrationEndTime,
        uint64 _allocationStartTime,
        uint64 _allocationEndTime
    ) public onlyPoolManager(msg.sender) {
        _updatePoolTimestamps(
            _registrationStartTime,
            _registrationEndTime,
            _allocationStartTime,
            _allocationEndTime
        );
    }

    /// @notice Getter for the 'CapyCore' contract.
    /// @return The CapyCore contract
    function getCapyCore() external view returns (ICapyCore) {
        return capyCore;
    }

    /// @notice Getter for the 'Token' contract.
    /// @return The Token contract
    function getToken() external view returns (IERC20) {
        return usdeToken;
    }

    /// @notice Returns the total number of registered recipients
    /// @return uint256 Total number of recipients
    function getTotalRecipients() external view returns (uint256) {
        return recipientList.length;
    }

    /// @notice Returns the details of a recipient
    /// @param _recipientAddress Address of the recipient
    /// @return Recipient struct containing recipient details
    function getRecipientDetails(
        address _recipientAddress
    ) external view returns (Recipient memory) {
        return recipients[_recipientAddress];
    }

    /// @notice Withdraws any remaining tokens from the contract
    /// @dev Can only be called by the owner
    function withdrawRemainingTokens() external onlyPoolManager(msg.sender) {
        uint256 remainingBalance = usdeToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            usdeToken.safeTransfer(owner(), remainingBalance);
        }
    }

    /// @notice Checks if address is eligible allocator.
    /// @return Always returns true for this strategy
    function _isValidAllocator(address) internal pure override returns (bool) {
        return true;
    }

    /// @notice Modifier to ensure the function is called during the active registration period
    modifier onlyActiveRegistration() {
        require(
            block.timestamp >= registrationStartTime &&
                block.timestamp <= registrationEndTime,
            "Registration is not active"
        );
        _;
    }

    /// @notice Modifier to ensure the function is called during the active allocation period
    modifier onlyActiveAllocation() {
        require(
            block.timestamp >= allocationStartTime &&
                block.timestamp <= allocationEndTime,
            "Allocation is not active"
        );
        _;
    }

    /// @notice Modifier to ensure the function is called after the allocation period has ended
    modifier onlyAfterAllocation() {
        require(
            block.timestamp > allocationEndTime,
            "Allocation period has not ended"
        );
        _;
    }
}
