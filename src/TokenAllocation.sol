// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@security/access/PauserControl.sol"; // PauserControl -> AccessControl -> Ownable

/**
 * @title TokenAllocation
 * @dev Abstract base contract for managing token allocations.
 * @author Brevis Network
 */
abstract contract TokenAllocation is PauserControl {
    // 0x73e573f9566d61418a34d5de3ff49360f9c51fec37f7486551670290f6285dab
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    mapping(address => uint256) public allocations; // Mapping from user address to their allocation details
    uint256 public totalAllocation; // Total tokens allocated across all users

    bool public allocationLocked; // Flag indicating whether allocations can be updated

    event AllocationSet(address indexed user, uint256 allocation);
    event AllocationsLocked();

    /**
     * @notice Sets or updates allocations for multiple users in a single transaction
     * @param _users Array of user addresses to set allocations for
     * @param _allocations Array of allocation amounts corresponding to each user
     */
    function setUserAllocations(address[] calldata _users, uint256[] calldata _allocations)
        external
        whenNotPaused
        onlyRole(UPDATER_ROLE)
    {
        require(!allocationLocked, "Allocations are locked");

        uint256 numUsers = _users.length;
        require(numUsers == _allocations.length, "Mismatched input lengths");

        uint256 currentTotalAllocation = totalAllocation;
        unchecked {
            for (uint256 i = 0; i < numUsers; ++i) {
                address user = _users[i];
                uint256 newAllocation = _allocations[i];
                uint256 currentAllocation = allocations[user];
                if (newAllocation != currentAllocation) {
                    allocations[user] = newAllocation;
                    // Safe arithmetic: update cached total
                    currentTotalAllocation = currentTotalAllocation + newAllocation - currentAllocation;
                    emit AllocationSet(user, newAllocation);
                }
            }
        }
        // Single storage write at the end
        totalAllocation = currentTotalAllocation;
    }

    /**
     * @notice Locks allocations to prevent further updates
     */
    function lockAllocations() external {
        require(hasRole(UPDATER_ROLE, msg.sender) || owner() == msg.sender, "Not authorized");
        require(!allocationLocked, "Allocations already locked");
        allocationLocked = true;
        emit AllocationsLocked();
    }
}
