// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import "@security/access/AccessControl.sol"; // AccessControl -> Ownable

/**
 * @title RewardsSubmission
 * @notice A contract for managing reward submissions and generating Merkle proofs for airdrops
 * @dev This contract allows trusted parties to submit user rewards, generate Merkle trees in batches
 *      to handle gas limitations, and provide proofs for users to claim their rewards on other chains.
 * @author Brevis Network
 */
contract RewardsSubmission is AccessControl {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // Role identifier for addresses that can update rewards and manage state
    // 9188644bf0c7a694e572b54fd40005e1230f80a50c59be6fb567a312ab5a1d4d
    bytes32 public constant REWARD_UPDATER_ROLE = keccak256("REWARD_UPDATER_ROLE");

    // Mapping of user addresses to their allocated reward amounts
    EnumerableMap.AddressToUintMap allocatedRewards;
    // Total amount of rewards allocated across all users
    uint256 totalAllocatedRewards;

    // State machine for the reward submission and Merkle tree generation process
    enum State {
        Idle,
        RewardsSubmission,
        SubRootsGeneration,
        TopRootGeneration,
        Completed
    }

    // Current state of the contract
    State public state;

    // Storage for Merkle tree generation
    EnumerableSet.Bytes32Set subRoots; // Set of generated subtree roots
    uint256[] subRootUserIndexStart; // Starting user indices for each subtree
    bytes32 public topRoot; // Final Merkle root of all subtrees

    event RewardsSet(address indexed user, uint256 allocatedRewards);
    event SubRootGenerated(uint256 indexed subRootIndex, bytes32 subRoot);
    event AllSubRootsGenerated();
    event TopRootGenerated(bytes32 topRoot);
    event GlobalStateUpdated(State indexed state);

    /**
     * @notice Initializes the contract with owner and reward updater roles
     * @param _owner Address that will have owner privileges
     * @param _rewardUpdater Address that can update rewards and manage state transitions
     */
    function init(address _owner, address _rewardUpdater) external {
        require(_owner != address(0), "invalid owner");
        require(_rewardUpdater != address(0), "invalid reward updater");
        require(owner() == address(0), "already initialized");

        initOwner(_owner);
        _grantRole(REWARD_UPDATER_ROLE, _rewardUpdater);
    }

    /**
     * @notice Gets the allocated rewards for a specific user
     * @param _user The user address to query
     * @return amount The allocated reward amount for the user (0 if not found)
     */
    function getAllocatedRewards(address _user) external view returns (uint256 amount) {
        (, amount) = allocatedRewards.tryGet(_user);
    }

    /**
     * @notice Sets or updates allocated rewards for multiple users
     * @dev Can only be called during the RewardsSubmission state. Updates totalAllocatedRewards accordingly.
     * @param _users Array of user addresses
     * @param _allocatedAmounts Array of allocated reward amounts corresponding to users
     */
    function setUserRewards(address[] calldata _users, uint256[] calldata _allocatedAmounts)
        external
        onlyRole(REWARD_UPDATER_ROLE)
    {
        require(state == State.RewardsSubmission, "not in rewards submission state");
        require(_users.length == _allocatedAmounts.length, "users and amounts length mismatch");
        require(_users.length > 0, "empty arrays");

        // Track the net change in total allocated rewards
        // Using signed integer to handle both increases and decreases
        int256 totalDifference = 0;
        for (uint256 i = 0; i < _users.length; i++) {
            require(_users[i] != address(0), "invalid user address");

            // Get the user's previous allocated amount (0 if not previously set)
            (, uint256 prevAllocatedRewards) = allocatedRewards.tryGet(_users[i]);
            // Calculate the difference: new amount - previous amount
            totalDifference += int256(_allocatedAmounts[i]) - int256(prevAllocatedRewards);
            // Update the user's allocated rewards in the enumerable map
            allocatedRewards.set(_users[i], _allocatedAmounts[i]);
            emit RewardsSet(_users[i], _allocatedAmounts[i]);
        }

        // Update the global total based on the net change
        if (totalDifference > 0) {
            // Net increase in allocations
            totalAllocatedRewards += uint256(totalDifference);
        } else if (totalDifference < 0) {
            // Net decrease in allocations (convert back to positive for subtraction)
            totalAllocatedRewards -= uint256(-totalDifference);
        }
        // If totalDifference == 0, no change needed to totalAllocatedRewards
    }

    // ----------- State transition functions -----------

    /**
     * @notice Starts the reward submission phase
     * @dev Transitions from Idle to RewardsSubmission state
     */
    function startSubmission() external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.Idle, "invalid state");
        state = State.RewardsSubmission;
    }

    /**
     * @notice Starts the subtree root generation phase
     * @dev Transitions from RewardsSubmission to SubRootsGeneration state and clears previous subtree data
     */
    function startSubRootGen() external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.RewardsSubmission, "invalid state");
        state = State.SubRootsGeneration;
        subRoots.clear();
    }

    /**
     * @notice Manually sets the contract state (for recovery purposes)
     * @dev Should be used carefully as it can disrupt the normal flow
     * @param _state The new state to set
     */
    function setGlobalState(State _state) external onlyOwner {
        state = _state;
        emit GlobalStateUpdated(state);
    }

    // ----------- Merkle tree generation functions -----------

    /**
     * @notice Generates and records a Merkle root for a subset of users up to `nLeaves`
     * @dev Should be called repeatedly until every user is covered in a subtree.
     *      Automatically transitions to TopRootGeneration state when all users are processed.
     * @param _nLeaves The maximal number of users to include in the current subtree
     */
    function genSubRoot(uint256 _nLeaves) external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.SubRootsGeneration, "invalid state");
        require(_nLeaves <= 2 ** 32, "too many leaves");

        // Get the current subtree index (how many subtrees we've already generated)
        uint256 subRootIndex = subRoots.length();
        uint256 indexStart = 0;

        // For the first subtree, clear any previous data and start from index 0
        if (subRootIndex == 0) {
            delete subRootUserIndexStart;
        } else {
            // For subsequent subtrees, continue from where the last subtree ended
            indexStart = subRootUserIndexStart[subRootIndex - 1];
        }

        // Calculate how many users remain to be processed
        uint256 maxNLeaves = allocatedRewards.length() - indexStart;
        // Cap the leaves to the remaining users if requested amount exceeds what's left
        if (_nLeaves > maxNLeaves) {
            _nLeaves = maxNLeaves;
        }

        // Create leaf hashes for this subtree batch
        bytes32[] memory hashes = new bytes32[](_nLeaves);
        for (uint256 i = 0; i < _nLeaves; i++) {
            // Get user address and reward amount from the enumerable map
            (address user, uint256 rewards) = allocatedRewards.at(indexStart + i);
            // Create leaf hash by encoding user address and reward amount together
            bytes32 leafHash = keccak256(abi.encodePacked(user, rewards));
            hashes[i] = leafHash;
        }

        // Generate the Merkle root for this subtree
        bytes32 subRoot = genMerkleRoot(hashes);
        // Add this subtree root to our collection
        subRoots.add(subRoot);
        emit SubRootGenerated(subRootIndex, subRoot);

        // Check if we've processed all users
        if (_nLeaves == maxNLeaves) {
            // All users are covered, ready to generate the final top root
            state = State.TopRootGeneration;
            emit AllSubRootsGenerated();
        } else {
            // Record where the next subtree should start
            subRootUserIndexStart.push(indexStart + _nLeaves);
        }
    }

    /**
     * @notice Generates and records the top Merkle tree root using subtree roots as leaves
     * @dev Transitions the contract to Completed state. Can only be called after all subtrees are generated.
     */
    function genTopRoot() external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.TopRootGeneration, "invalid state");
        // Create the final Merkle root using all subtree roots as leaves
        // This creates a two-level Merkle tree structure: individual user subtrees → top root
        topRoot = genMerkleRoot(subRoots.values());
        state = State.Completed;
        emit TopRootGenerated(topRoot);
    }

    /**
     * @notice Generates a Merkle root from an array of hashes
     * @dev Uses commutative keccak256 for hash combining. Handles odd number of leaves by promoting the last leaf.
     * @param _hashes Array of leaf hashes to build the Merkle tree from
     * @return merkleRoot The computed Merkle root
     */
    function genMerkleRoot(bytes32[] memory _hashes) internal pure returns (bytes32 merkleRoot) {
        // Handle empty array edge case
        if (_hashes.length == 0) {
            return bytes32(0);
        }

        // Build the Merkle tree bottom-up by repeatedly pairing and hashing adjacent nodes
        while (_hashes.length > 1) {
            // Create array for the next level (half the size, rounded up for odd counts)
            bytes32[] memory nextHashes = new bytes32[]((_hashes.length + 1) / 2);
            uint256 i;

            // Process pairs of hashes
            for (; i < _hashes.length - 1; i += 2) {
                // Combine pairs using commutative hash (order-independent)
                // This ensures the same root regardless of the order hashes are provided
                nextHashes[i / 2] = Hashes.commutativeKeccak256(_hashes[i], _hashes[i + 1]);
            }

            // Handle odd number of hashes: promote the last hash to next level
            if (i == _hashes.length - 1) {
                nextHashes[i / 2] = _hashes[i];
            }

            // Move up one level in the tree
            _hashes = nextHashes;
        }

        // The final remaining hash is our Merkle root
        return _hashes[0];
    }

    /**
     * @notice Generates a Merkle proof for a specific user
     * @dev Combines sub-tree proof and top-tree proof into a single proof array
     * @param _user The user address to generate proof for
     * @return allocatedAmount The allocated rewards for the user
     * @return proof The complete Merkle proof array from leaf to top root
     */
    function getMerkleProof(address _user) external view returns (uint256 allocatedAmount, bytes32[] memory proof) {
        require(state == State.Completed, "invalid state");

        // Get the user's allocated reward amount
        allocatedAmount = allocatedRewards.get(_user);

        // Find the user's global index in the enumerable map
        // This uses internal OpenZeppelin structure to get position efficiently
        uint256 userIndex = allocatedRewards._inner._keys._inner._positions[bytes32(uint256(uint160(_user)))] - 1;

        // Determine which subtree contains this user
        uint256 subRootIndex;
        // Iterate through subtree boundaries to find the correct subtree
        while (subRootIndex < subRoots.length() - 1 && userIndex >= subRootUserIndexStart[subRootIndex]) {
            ++subRootIndex;
        }

        // Calculate the boundaries of the subtree containing our user
        uint256 indexStart = subRootIndex == 0 ? 0 : subRootUserIndexStart[subRootIndex - 1];
        uint256 nLeaves = allocatedRewards.length() - indexStart;
        // Adjust for non-final subtrees (exclude users in later subtrees)
        if (subRootIndex < subRoots.length() - 1) {
            nLeaves -= allocatedRewards.length() - subRootUserIndexStart[subRootIndex];
        }

        // Recreate the leaf hashes for the user's subtree
        // This is necessary because we only store the subtree roots, not the individual leaves
        bytes32[] memory hashes = new bytes32[](nLeaves);
        for (uint256 i = 0; i < hashes.length; i++) {
            (address _user2, uint256 rewards) = allocatedRewards.at(indexStart + i);
            // Create the same leaf hash as used in genSubRoot
            hashes[i] = keccak256(abi.encodePacked(_user2, rewards));
        }

        // Generate proof from user's leaf to subtree root
        bytes32[] memory subProof = genMerkleProof(hashes, userIndex - indexStart);

        // Generate proof from subtree root to top root
        bytes32[] memory topProof = genMerkleProof(subRoots.values(), subRootIndex);

        // Combine both proofs into a single array
        // The verification process will first verify against the subtree root,
        // then continue from that root to verify against the top root
        proof = new bytes32[](subProof.length + topProof.length);
        for (uint256 i = 0; i < subProof.length; i++) {
            proof[i] = subProof[i];
        }
        for (uint256 i = 0; i < topProof.length; i++) {
            proof[subProof.length + i] = topProof[i];
        }
    }

    /**
     * @notice Generates a Merkle proof for a leaf at a specific path in the tree
     * @dev Internal function used by getMerkleProof. Builds proof bottom-up.
     * @param _hashes Array of hashes representing the current level of the tree
     * @param _path The path index of the target leaf (gets right-shifted as we go up levels)
     * @return proof Array of sibling hashes needed to verify the leaf
     */
    function genMerkleProof(bytes32[] memory _hashes, uint256 _path) internal pure returns (bytes32[] memory proof) {
        // Allocate maximum possible proof size (32 levels for 2^32 leaves)
        proof = new bytes32[](32);

        uint256 length = 0;
        while (_hashes.length > 1) {
            // Only add sibling to proof if:
            // 1. Even number of hashes (every node has a sibling), OR
            // 2. Current path is not the last unpaired node
            if (_hashes.length % 2 == 0 || _path < _hashes.length - 1) {
                // XOR with 1 flips the last bit: if _path is even, get odd sibling and vice versa
                // This efficiently finds the sibling node at the current level
                proof[length] = _hashes[_path ^ 1];
                ++length;
            }

            // Move up one level: divide path by 2 (right shift)
            // In a binary tree, parent index = child index / 2
            _path >>= 1;

            // Build the next level of the tree by pairing and hashing adjacent nodes
            bytes32[] memory nextHashes = new bytes32[]((_hashes.length + 1) / 2);
            uint256 i;
            for (; i < _hashes.length - 1; i += 2) {
                // Hash pairs using commutative hash function
                nextHashes[i / 2] = Hashes.commutativeKeccak256(_hashes[i], _hashes[i + 1]);
            }
            // Handle odd number: promote last hash without pairing
            if (i == _hashes.length - 1) {
                nextHashes[i / 2] = _hashes[i];
            }
            _hashes = nextHashes;
        }

        // Resize the proof array to actual length to save gas
        // Uses assembly for efficient memory manipulation
        assembly ("memory-safe") {
            mstore(proof, length)
        }
    }

    /**
     * @notice Get comprehensive contract status information
     * @return currentState The current state of the contract
     * @return userCount Total number of users with allocated rewards
     * @return totalAllocated Total amount of rewards allocated
     * @return subTreeCount Number of subtrees generated
     * @return finalRoot The final top root (if completed)
     */
    function getContractInfo()
        external
        view
        returns (State currentState, uint256 userCount, uint256 totalAllocated, uint256 subTreeCount, bytes32 finalRoot)
    {
        currentState = state;
        userCount = allocatedRewards.length();
        totalAllocated = totalAllocatedRewards;
        subTreeCount = subRoots.length();
        finalRoot = topRoot;
    }

    /**
     * @notice Get subtree generation progress
     * @return processedUsers Number of users already processed into subtrees
     * @return remainingUsers Number of users still to be processed
     * @return subTreeCount Number of subtrees generated so far
     */
    function getProgress()
        external
        view
        returns (uint256 processedUsers, uint256 remainingUsers, uint256 subTreeCount)
    {
        subTreeCount = subRoots.length();

        if (subTreeCount == 0) {
            processedUsers = 0;
        } else {
            processedUsers = subRootUserIndexStart.length > 0
                ? subRootUserIndexStart[subRootUserIndexStart.length - 1]
                : allocatedRewards.length();
        }

        remainingUsers = allocatedRewards.length() - processedUsers;
    }

    /**
     * @notice Check if a user has been allocated rewards
     * @param _user The user address to check
     * @return exists Whether the user has an allocation
     * @return amount The allocated amount (0 if user doesn't exist)
     */
    function hasAllocation(address _user) external view returns (bool exists, uint256 amount) {
        return allocatedRewards.tryGet(_user);
    }
}
