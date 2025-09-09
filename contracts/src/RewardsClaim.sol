// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import "@security/access/PauserControl.sol"; // PauserControl -> AccessControl -> Ownable

contract RewardsClaim is PauserControl {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10000; // 100.00%

    // 009ab23a1010d07a0450a1fbea1d84169b57d2c2273b54bff0f20c3e90199b5d
    bytes32 public constant ROOT_UPDATER_ROLE = keccak256("ROOT_UPDATER_ROLE");

    address public rewardToken;

    mapping(address => uint256) public userClaimed;

    uint256 public totalClaimed;

    bytes32 public topRoot;

    uint256 public initReleaseBps; // in basis points, e.g. 1000 = 10.00%
    uint256 public releaseStartTime; // timestamp
    uint256 public releaseDuration; // in seconds

    event TopRootUpdated(bytes32 topRoot);
    event UserRewardsClaimed(address indexed user, uint256 newAmount, uint256 claimedAmount, uint256 cumulativeAmounts);

    function init(address owner, address rootUpdater, address pauser, address _rewardToken) external {
        initOwner(owner);
        _grantRole(ROOT_UPDATER_ROLE, rootUpdater);
        _grantRole(PAUSER_ROLE, pauser);
        rewardToken = _rewardToken;
    }

    /**
     * @notice Set the epoch and top Merkle root info
     * @param _topRoot The Merkle root for the top tree.
     */
    function setRoot(bytes32 _topRoot) external onlyRole(ROOT_UPDATER_ROLE) {
        require(topRoot == bytes32(0), "top root already set");
        topRoot = _topRoot;
        emit TopRootUpdated(topRoot);
    }

    /**
     * @notice Claims rewards for a user using a combined sub tree + top tree Merkle proof.
     * @param user The user address.
     * @param cumulativeAmount The cumulative reward amount.
     * @param proof The Merkle proof from the sub tree leaf node to the top tree root.
     */
    function claim(address user, uint256 cumulativeAmount, bytes32[] calldata proof) external {
        require(cumulativeAmount > userClaimed[user], "no new rewards to claim");
        bytes32 leafHash = keccak256(abi.encodePacked(user, cumulativeAmount));
        require(verifyMerkleProof(proof, topRoot, leafHash), "verification failed");
        uint256 releasedAmount = releaseSchedule(cumulativeAmount, block.timestamp);
        require(releasedAmount > userClaimed[user], "no new released rewards to claim");
        uint256 newAmount = releasedAmount - userClaimed[user];
        userClaimed[user] += newAmount;
        totalClaimed += newAmount;
        // Send reward token
        IERC20(rewardToken).safeTransfer(user, newAmount);
        emit UserRewardsClaimed(user, newAmount, userClaimed[user], cumulativeAmount);
    }

    function verifyMerkleProof(bytes32[] memory proof, bytes32 root, bytes32 leafHash) private pure returns (bool) {
        bytes32 hash = leafHash;
        for (uint256 i = 0; i < proof.length; i++) {
            hash = Hashes.commutativeKeccak256(hash, proof[i]);
        }
        return hash == root;
    }

    function releaseSchedule(uint256 totalAmount, uint256 timestamp) public view returns (uint256) {
        if (timestamp < releaseStartTime) {
            // Before releaseStartTime, nothing is released
            return 0;
        } else if (timestamp == releaseStartTime) {
            // At releaseStartTime, initial percentage is released
            return (totalAmount * initReleaseBps) / BPS_DENOMINATOR;
        } else if (timestamp >= releaseStartTime + releaseDuration) {
            // After release period, all tokens are released
            return totalAmount;
        } else {
            // After releaseStartTime, initial percentage is released, rest linearly
            uint256 initial = (totalAmount * initReleaseBps) / BPS_DENOMINATOR;
            uint256 remaining = totalAmount - initial;
            uint256 elapsed = timestamp - releaseStartTime;
            uint256 linearReleased = (remaining * elapsed) / releaseDuration;
            return initial + linearReleased;
        }
    }

    function setReleaseParams(uint256 _initReleaseBps, uint256 _releaseDuration, uint256 _releaseStartTime)
        external
        onlyOwner
    {
        require(_initReleaseBps <= BPS_DENOMINATOR, "invalid initReleaseBps");
        require(_releaseDuration > 0, "invalid releaseDuration");
        require(releaseStartTime == 0, "already set");
        initReleaseBps = _initReleaseBps;
        releaseDuration = _releaseDuration;
        releaseStartTime = _releaseStartTime;
    }
}
