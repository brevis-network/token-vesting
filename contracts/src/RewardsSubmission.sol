// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/cryptography/Hashes.sol";

import "@security/access/PauserControl.sol"; // PauserControl -> AccessControl -> Ownable

contract RewardsSubmission is PauserControl {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // 9188644bf0c7a694e572b54fd40005e1230f80a50c59be6fb567a312ab5a1d4d
    bytes32 public constant REWARD_UPDATER_ROLE = keccak256("REWARD_UPDATER_ROLE");

    EnumerableMap.AddressToUintMap cumulativeRewards;
    uint256 totalSubmittedRewards;

    enum State {
        Idle,
        RewardsSubmission,
        SubRootsGeneration,
        TopRootGeneration
    }

    State public state;
    uint64 public currEpoch;

    // Storage for merkle roots generation
    EnumerableSet.Bytes32Set subRoots;
    uint256[] subRootUserIndexStart;
    bytes32 public topRoot;

    event RewardsSet(address indexed user, uint256 cumulativeRewards);
    event EpochStarted(uint64 indexed epoch);
    event EpochRestarted(uint64 indexed epoch);
    event SubRootGenStarted(uint64 indexed epoch);
    event SubRootLeafProcessed(
        uint64 indexed epoch,
        uint256 indexed subRootIndex,
        uint256 indexed leafIndex,
        address user,
        uint256 cumulativeRewards,
        bytes32 leafHash
    );
    event SubRootGenerated(uint64 indexed epoch, uint256 indexed subRootIndex, bytes32 subRoot);
    event AllSubRootsGenerated(uint64 indexed epoch);
    event TopRootGenerated(uint64 indexed epoch, bytes32 topRoot);
    event TopRootSent(uint64 indexed epoch, bytes32 topRoot, address receiver, uint64 dstChainId);
    event BrevisProofUpdated(address brevisProof);
    event GlobalStateUpdated(uint64 indexed currEpoch, State indexed state);

    function init(address owner, address _rewardUpdater) external {
        initOwner(owner);
        _grantRole(REWARD_UPDATER_ROLE, _rewardUpdater);
    }

    function getCumulativeRewards(address user) external view returns (uint256 amount) {
        (, amount) = cumulativeRewards.tryGet(user);
        return amount;
    }

    function setUserRewards(address[] calldata users, uint256[] calldata cumulativeAmounts)
        external
        onlyRole(REWARD_UPDATER_ROLE)
    {
        require(state == State.RewardsSubmission, "not in rewards submission state");
        require(users.length == cumulativeAmounts.length, "users and amounts length mismatch");

        int256 totalDifference = 0;
        for (uint256 i = 0; i < users.length; i++) {
            (, uint256 prevCumulativeRewards) = cumulativeRewards.tryGet(users[i]);
            totalDifference += int256(cumulativeAmounts[i]) - int256(prevCumulativeRewards);
            cumulativeRewards.set(users[i], cumulativeAmounts[i]);
            emit RewardsSet(users[i], cumulativeAmounts[i]);
        }
        if (totalDifference > 0) {
            totalSubmittedRewards += uint256(totalDifference);
        } else if (totalDifference < 0) {
            totalSubmittedRewards -= uint256(-totalDifference);
        }
    }

    // ----------- state transition -----------
    function startEpoch(uint64 epoch) external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.Idle, "invalid state");
        require(epoch > currEpoch, "invalid epoch");
        currEpoch = epoch;
        state = State.RewardsSubmission;
        emit EpochStarted(epoch);
    }

    function restartEpoch(uint64 epoch) external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.Idle, "invalid state");
        require(epoch == currEpoch, "can only restart current epoch");
        state = State.RewardsSubmission;
        emit EpochRestarted(epoch);
    }

    function startSubRootGen(uint64 epoch) external onlyRole(REWARD_UPDATER_ROLE) {
        require(state == State.RewardsSubmission, "invalid state");
        require(currEpoch == epoch, "invalid epoch");
        state = State.SubRootsGeneration;
        subRoots.clear();
        emit SubRootGenStarted(epoch);
    }

    function setGlobalState(uint64 _currEpoch, State _state) external onlyRole(REWARD_UPDATER_ROLE) {
        currEpoch = _currEpoch;
        state = _state;
        emit GlobalStateUpdated(currEpoch, state);
    }

    // ----------- Merkle Roots Generation -----------

    /**
     * @notice Generates and records a Merkle root for a subset of users up to `nLeaves`.
     *    Should be called repeatedly until every user is covered in a subtree.
     * @param epoch The epoch.
     * @param nLeaves The maximal number of users to include in the current subtree.
     */
    function genSubRoot(uint64 epoch, uint256 nLeaves) external {
        require(state == State.SubRootsGeneration, "invalid state");
        require(epoch == currEpoch, "invalid epoch");
        require(nLeaves <= 2 ** 32, "too many leaves");

        uint256 subRootIndex = subRoots.length();
        uint256 indexStart = 0;
        if (subRootIndex == 0) {
            delete subRootUserIndexStart;
        } else {
            indexStart = subRootUserIndexStart[subRootIndex - 1];
        }

        uint256 maxNLeaves = cumulativeRewards.length() - indexStart;
        if (nLeaves > maxNLeaves) {
            nLeaves = maxNLeaves;
        }
        bytes32[] memory hashes = new bytes32[](nLeaves);
        for (uint256 i = 0; i < nLeaves; i++) {
            (address user, uint256 rewards) = cumulativeRewards.at(indexStart + i);
            bytes32 leafHash = keccak256(abi.encodePacked(user, rewards));
            hashes[i] = leafHash;
            emit SubRootLeafProcessed(epoch, subRootIndex, i, user, rewards, leafHash);
        }
        bytes32 subRoot = genMerkleRoot(hashes);
        subRoots.add(subRoot);
        emit SubRootGenerated(epoch, subRootIndex, subRoot);

        if (nLeaves == maxNLeaves) {
            state = State.TopRootGeneration;
            emit AllSubRootsGenerated(epoch);
        } else {
            subRootUserIndexStart.push(indexStart + nLeaves);
        }
    }

    /**
     * @notice Generates and records the top Merkle tree root, using the subtree roots as leaves.
     * @param epoch The epoch.
     */
    function genTopRoot(uint64 epoch) external {
        require(state == State.TopRootGeneration, "invalid state");
        require(epoch == currEpoch, "invalid epoch");
        topRoot = genMerkleRoot(subRoots.values());
        state = State.Idle;
        emit TopRootGenerated(epoch, topRoot);
    }

    function genMerkleRoot(bytes32[] memory hashes) internal pure returns (bytes32) {
        if (hashes.length == 0) {
            return bytes32(0);
        }
        while (hashes.length > 1) {
            bytes32[] memory nextHashes = new bytes32[]((hashes.length + 1) / 2);
            uint256 i;
            for (; i < hashes.length - 1; i += 2) {
                nextHashes[i / 2] = Hashes.commutativeKeccak256(hashes[i], hashes[i + 1]);
            }
            if (i == hashes.length - 1) {
                nextHashes[i / 2] = hashes[i];
            }
            hashes = nextHashes;
        }
        return hashes[0];
    }

    function getMerkleProof(uint64 epoch, address user)
        external
        view
        returns (uint256 _cumulativeRewards, bytes32[] memory proof)
    {
        require(state == State.Idle, "invalid state");
        require(epoch == currEpoch, "invalid epoch");

        _cumulativeRewards = cumulativeRewards.get(user);

        uint256 userIndex = cumulativeRewards._inner._keys._inner._positions[bytes32(uint256(uint160(user)))] - 1;

        uint256 subRootIndex;
        while (subRootIndex < subRoots.length() - 1 && userIndex >= subRootUserIndexStart[subRootIndex]) {
            ++subRootIndex;
        }

        uint256 indexStart = subRootIndex == 0 ? 0 : subRootUserIndexStart[subRootIndex - 1];
        uint256 nLeaves = cumulativeRewards.length() - indexStart;
        if (subRootIndex < subRoots.length() - 1) {
            nLeaves -= cumulativeRewards.length() - subRootUserIndexStart[subRootIndex];
        }

        bytes32[] memory hashes = new bytes32[](nLeaves);
        for (uint256 i = 0; i < hashes.length; i++) {
            (address _user, uint256 rewards) = cumulativeRewards.at(indexStart + i);
            hashes[i] = keccak256(abi.encodePacked(_user, rewards));
        }
        bytes32[] memory subProof = genMerkleProof(hashes, userIndex - indexStart);

        bytes32[] memory topProof = genMerkleProof(subRoots.values(), subRootIndex);

        proof = new bytes32[](subProof.length + topProof.length);
        for (uint256 i = 0; i < subProof.length; i++) {
            proof[i] = subProof[i];
        }
        for (uint256 i = 0; i < topProof.length; i++) {
            proof[subProof.length + i] = topProof[i];
        }
    }

    function genMerkleProof(bytes32[] memory hashes, uint256 path) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](32);

        uint256 length = 0;
        while (hashes.length > 1) {
            if (hashes.length % 2 == 0 || path < hashes.length - 1) {
                proof[length] = hashes[path ^ 1];
                ++length;
            }
            path >>= 1;

            bytes32[] memory nextHashes = new bytes32[]((hashes.length + 1) / 2);
            uint256 i;
            for (; i < hashes.length - 1; i += 2) {
                nextHashes[i / 2] = Hashes.commutativeKeccak256(hashes[i], hashes[i + 1]);
            }
            if (i == hashes.length - 1) {
                nextHashes[i / 2] = hashes[i];
            }
            hashes = nextHashes;
        }

        assembly ("memory-safe") {
            mstore(proof, length)
        }
    }
}
