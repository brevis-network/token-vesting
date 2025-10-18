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

    mapping(address => uint256) public allocations; // Mapping from beneficiary address to their allocation amount
    uint256 public totalAllocation; // Total tokens allocated across all beneficiaries

    bool public allocationLocked; // Flag indicating whether allocations can be updated

    event AllocationSet(address indexed beneficiary, uint256 allocation);
    event TotalAllocationSet(uint256 totalAllocation);
    event AllocationsLocked();

    /**
     * @notice Sets or updates allocations for multiple beneficiaries in a single transaction
     * @param _beneficiaries Array of beneficiary addresses to set allocations for
     * @param _allocations Array of allocation amounts corresponding to each beneficiary
     */
    function setAllocations(address[] calldata _beneficiaries, uint256[] calldata _allocations)
        external
        whenNotPaused
        onlyRole(UPDATER_ROLE)
    {
        require(!allocationLocked, "Allocations are locked");

        uint256 numBeneficiaries = _beneficiaries.length;
        require(numBeneficiaries == _allocations.length, "Mismatched input lengths");

        uint256 currentTotalAllocation = totalAllocation;
        unchecked {
            for (uint256 i = 0; i < numBeneficiaries; ++i) {
                address beneficiary = _beneficiaries[i];
                require(beneficiary != address(0), "zero beneficiary");
                uint256 newAllocation = _allocations[i];
                uint256 currentAllocation = allocations[beneficiary];
                if (newAllocation != currentAllocation) {
                    allocations[beneficiary] = newAllocation;
                    // Safe arithmetic: update cached total
                    currentTotalAllocation = currentTotalAllocation + newAllocation - currentAllocation;
                    emit AllocationSet(beneficiary, newAllocation);
                }
            }
        }
        // Single storage write at the end
        totalAllocation = currentTotalAllocation;
        emit TotalAllocationSet(totalAllocation);
    }

    /**
     * @notice Locks allocations to prevent further updates
     */
    function lockAllocations() external onlyOwner {
        require(!allocationLocked, "Allocations already locked");
        allocationLocked = true;
        emit AllocationsLocked();
    }

    /**
     * @notice Get allocations for multiple beneficiaries
     * @dev External helper for off-chain tools to fetch multiple allocations in one call,
     *      reducing RPC round-trips when checking on-chain state against CSV or other
     *      off-chain datasets.
     * @param _beneficiaries Array of beneficiary addresses to query
     * @return amounts Array of allocation amounts corresponding to each beneficiary
     */
    function getAllocations(address[] calldata _beneficiaries) external view returns (uint256[] memory amounts) {
        uint256 n = _beneficiaries.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            amounts[i] = allocations[_beneficiaries[i]];
        }
    }
}
