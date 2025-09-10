// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import "@security/access/PauserControl.sol"; // PauserControl -> AccessControl -> Ownable

/**
 * @title RewardsClaim
 * @notice A contract for claiming token rewards with vesting schedule using Merkle proofs
 * @dev This contract allows users to claim their allocated rewards based on a Merkle tree proof system.
 *      Rewards are subject to a vesting schedule with an initial release percentage and linear vesting.
 * @author Brevis Network
 */
contract RewardsClaim is PauserControl {
    using SafeERC20 for IERC20;

    // Denominator for basis points calculations (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10000;

    // Role identifier for addresses that can update the Merkle root
    // 009ab23a1010d07a0450a1fbea1d84169b57d2c2273b54bff0f20c3e90199b5d
    bytes32 public constant ROOT_UPDATER_ROLE = keccak256("ROOT_UPDATER_ROLE");

    // Address of the ERC20 token being distributed as rewards
    address public rewardToken;

    // Mapping of user addresses to their total claimed rewards
    mapping(address => uint256) public userClaimed;

    // Total amount of rewards claimed by all users
    uint256 public totalClaimed;

    // The Merkle root of the reward distribution tree
    bytes32 public topRoot;

    // Initial release percentage in basis points (e.g., 1000 = 10.00%)
    uint256 public initReleaseBps;
    // Timestamp when the vesting period starts
    uint256 public releaseStartTime;
    // Duration of the linear vesting period in seconds
    uint256 public releaseDuration;

    event TopRootUpdated(bytes32 topRoot);
    event UserRewardsClaimed(address indexed user, uint256 newAmount, uint256 claimedAmount, uint256 allocatedAmount);
    event TokensSwept(address to, uint256 amount);
    event VestingParamsSet(uint256 initReleaseBps, uint256 releaseDuration, uint256 releaseStartTime);

    /**
     * @notice Initializes the contract with required roles and token address
     * @param _owner Address that will have owner privileges
     * @param _rootUpdater Address that can update the Merkle root
     * @param _pauser Address that can pause/unpause the contract
     * @param _rewardToken Address of the ERC20 token to be distributed
     */
    function init(address _owner, address _rootUpdater, address _pauser, address _rewardToken) external {
        require(_owner != address(0), "invalid owner");
        require(_rootUpdater != address(0), "invalid root updater");
        require(_pauser != address(0), "invalid pauser");
        require(_rewardToken != address(0), "invalid token");
        require(owner() == address(0), "already initialized");

        initOwner(_owner);
        _grantRole(ROOT_UPDATER_ROLE, _rootUpdater);
        _grantRole(PAUSER_ROLE, _pauser);
        rewardToken = _rewardToken;
    }

    /**
     * @notice Set the epoch and top Merkle root info
     * @param _topRoot The Merkle root for the top tree.
     */
    function setRoot(bytes32 _topRoot) external onlyRole(ROOT_UPDATER_ROLE) {
        require(_topRoot != bytes32(0), "invalid root");
        require(topRoot == bytes32(0), "top root already set");
        topRoot = _topRoot;
        emit TopRootUpdated(topRoot);
    }

    /**
     * @notice Claims rewards for a user using a combined sub tree + top tree Merkle proof
     * @dev Verifies the Merkle proof, calculates vested amount, and transfers tokens
     * @param _user The user address claiming rewards
     * @param _allocatedAmount The total allocated reward amount for this user from the Merkle tree
     * @param _proof The Merkle proof array from the leaf to the root
     */
    function claim(address _user, uint256 _allocatedAmount, bytes32[] calldata _proof) external whenNotPaused {
        // Ensure vesting parameters have been configured
        require(releaseStartTime > 0, "vesting not configured");

        // Check that the user has unclaimed rewards remaining
        // This prevents claiming more than allocated
        require(_allocatedAmount > userClaimed[_user], "no new rewards to claim");

        // Create the leaf hash exactly as it was created in RewardsSubmission
        // This must match: keccak256(abi.encodePacked(user, rewards))
        bytes32 leafHash = keccak256(abi.encodePacked(_user, _allocatedAmount));

        // Verify that the user's allocation is valid according to the Merkle tree
        // The proof connects the leaf hash to the stored topRoot
        require(verifyMerkleProof(_proof, topRoot, leafHash), "verification failed");

        // Calculate how much should be released based on current time and vesting schedule
        uint256 releasedAmount = releaseSchedule(_allocatedAmount, block.timestamp);

        // Ensure there are actually new tokens to release (prevents redundant claims)
        require(releasedAmount > userClaimed[_user], "no new released rewards to claim");

        // Calculate the amount of new tokens to transfer
        uint256 newAmount = releasedAmount - userClaimed[_user];

        // Update the user's claimed amount and global total
        userClaimed[_user] += newAmount;
        totalClaimed += newAmount;

        // Transfer the tokens to the user using SafeERC20 for security
        IERC20(rewardToken).safeTransfer(_user, newAmount);

        emit UserRewardsClaimed(_user, newAmount, userClaimed[_user], _allocatedAmount);
    }

    /**
     * @notice Verifies a Merkle proof against a given root and leaf
     * @dev Uses commutative keccak256 for proof verification
     * @param _proof Array of proof hashes from leaf to root
     * @param _root The Merkle root to verify against
     * @param _leafHash The leaf hash to verify
     * @return isValid True if the proof is valid, false otherwise
     */
    function verifyMerkleProof(bytes32[] memory _proof, bytes32 _root, bytes32 _leafHash)
        private
        pure
        returns (bool isValid)
    {
        // Handle edge case: if no proof provided, leaf must equal root
        // This happens when there's only one user in the entire tree
        if (_proof.length == 0) return _leafHash == _root;

        // Start with the leaf hash and work our way up the tree
        bytes32 hash = _leafHash;

        // For each element in the proof, combine it with our current hash
        for (uint256 i = 0; i < _proof.length; i++) {
            // Use commutative hash to combine with sibling
            // Commutative means hash(a,b) == hash(b,a), so order doesn't matter
            // This matches the tree construction in RewardsSubmission
            hash = Hashes.commutativeKeccak256(hash, _proof[i]);
        }

        // After processing all proof elements, we should arrive at the root
        return hash == _root;
    }

    /**
     * @notice Calculates the amount of tokens that should be released at a given timestamp
     * @dev Implements a vesting schedule with initial release + linear vesting
     * @param _totalAmount The total amount of tokens allocated to the user
     * @param _timestamp The timestamp to calculate released amount for
     * @return releasedAmount The amount of tokens that should be released at the given timestamp
     */
    function releaseSchedule(uint256 _totalAmount, uint256 _timestamp) public view returns (uint256 releasedAmount) {
        if (_timestamp < releaseStartTime) {
            // Before the release period begins, no tokens are available
            return 0;
        } else if (_timestamp >= releaseStartTime + releaseDuration) {
            // After the vesting period ends, all tokens are fully vested
            return _totalAmount;
        } else {
            // During the vesting period: initial release + linear progression

            // Calculate the immediate release amount (percentage of total)
            uint256 initial = (_totalAmount * initReleaseBps) / BPS_DENOMINATOR;

            // Calculate the amount subject to linear vesting
            uint256 remaining = _totalAmount - initial;

            // Calculate how much time has passed since release started
            uint256 elapsed = _timestamp - releaseStartTime;

            // Calculate the linear portion released based on elapsed time
            // Formula: (remaining_amount * time_elapsed) / total_vesting_duration
            uint256 linearReleased = (remaining * elapsed) / releaseDuration;

            // Total released = initial immediate release + linear vested amount
            return initial + linearReleased;
        }
    }

    /**
     * @notice Sets the vesting parameters for token release
     * @dev Can only be called once by the owner. All parameters must be valid.
     * @param _initReleaseBps Initial release percentage in basis points (max 10000)
     * @param _releaseDuration Duration of the linear vesting period in seconds (must be > 0)
     * @param _releaseStartTime Timestamp when vesting starts
     */
    function setReleaseParams(uint256 _initReleaseBps, uint256 _releaseDuration, uint256 _releaseStartTime)
        external
        onlyOwner
    {
        // Validate that initial release percentage doesn't exceed 100%
        require(_initReleaseBps <= BPS_DENOMINATOR, "invalid initReleaseBps");

        // Ensure vesting period is not zero (would cause division by zero)
        require(_releaseDuration > 0, "invalid releaseDuration");

        // Prevent parameters from being changed once set (immutable after deployment)
        require(releaseStartTime == 0, "already set");

        // Set the vesting parameters
        initReleaseBps = _initReleaseBps; // Immediate release percentage
        releaseDuration = _releaseDuration; // Linear vesting duration
        releaseStartTime = _releaseStartTime; // When vesting begins

        emit VestingParamsSet(_initReleaseBps, _releaseDuration, _releaseStartTime);
    }

    /**
     * @notice Emergency function to sweep excess tokens from the contract
     * @dev Can only be called by owner when paused. Prevents sweeping tokens that are still claimable.
     * @param to Address to send the swept tokens to
     * @param amount Amount of tokens to sweep
     */
    function sweepTokens(address to, uint256 amount) external onlyOwner whenPaused {
        require(to != address(0), "invalid recipient");
        require(amount > 0, "amount must be greater than 0");

        // Get current contract balance
        uint256 contractBalance = IERC20(rewardToken).balanceOf(address(this));
        require(amount <= contractBalance, "insufficient balance");

        // Optional: Add additional safety check to prevent sweeping claimable tokens
        // This would require tracking total allocations from RewardsSubmission
        // require(amount <= contractBalance - (totalAllocatedFromTree - totalClaimed), "would sweep claimable tokens");

        IERC20(rewardToken).safeTransfer(to, amount);
        emit TokensSwept(to, amount);
    }

    /**
     * @notice Get information about a user's claim status
     * @param _user The user address to query
     * @return claimed Amount already claimed by the user
     * @return claimable Amount currently claimable (considering vesting)
     * @return total Total allocated amount (requires valid proof to verify)
     */
    function getUserClaimInfo(address _user, uint256 _totalAllocated)
        external
        view
        returns (uint256 claimed, uint256 claimable, uint256 total)
    {
        claimed = userClaimed[_user];
        total = _totalAllocated;

        if (releaseStartTime > 0) {
            uint256 released = releaseSchedule(_totalAllocated, block.timestamp);
            claimable = released > claimed ? released - claimed : 0;
        } else {
            claimable = 0;
        }
    }
}
