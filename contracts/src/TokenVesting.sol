// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./TokenAllocation.sol";

/**
 * @title TokenVesting
 * @dev A token vesting contract that allows for flexible vesting schedules with initial unlocking
 * and linear vesting over time. Supports role-based access control and emergency pause functionality.
 *
 * Operational sequence and assumptions:
 * - This contract is intended for a fully trusted, standard ERC20 token (no fees, no rebasing).
 * - Deployment: `token`, `UPDATER_ROLE`, and `PAUSER_ROLE` may be provided at construction time.
 *   Passing zero addresses is allowed, and the owner may set the addresses later.
 * - Configuration before user claims:
 *   1) Owner sets vesting parameters via {setVestingParameters} (init bps, start time, duration).
 *   2) Updater sets/updates user allocations via {setUserAllocations}.
 *   3) Lock allocations via {lockAllocations}. After locking:
 *      - {setUserAllocations}, {setVestingParameters}, and {setToken} are no longer callable.
 *      - Users can start calling {release} once vesting has started.
 *   4) Fund the contract with the vesting token so it can cover upcoming releases (not enforced on-chain).
 *
 * - Claiming: Users call {release} when not paused. It transfers the currently vested, unreleased amount.
 * - Pausing/Emergency: Accounts with PAUSER_ROLE can pause/unpause; when paused, {release} is disabled,
 *   and the owner can rescue the vesting token via {sweepTokens}.
 * @author Brevis Network
 */
contract TokenVesting is TokenAllocation {
    using SafeERC20 for IERC20;

    // Denominator for basis points calculations (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10000;

    IERC20 public token; // standard (no fees/rebases) token being vested

    mapping(address => uint256) public released; // Mapping from user address to their released tokens
    uint256 public totalReleased; // Total tokens released across all users

    uint256 public initVestedBps; // Initial vested percentage in basis points (e.g., 1000 = 10.00%)
    uint256 public vestingStartTime; // Timestamp when the vesting period starts
    uint256 public vestingDuration; // Duration of the linear vesting period in seconds

    event TokensReleased(address indexed user, uint256 amount);
    event VestingParametersSet(uint256 initVestedBps, uint256 vestingStartTime, uint256 vestingDuration);
    event TokenSet(address indexed token);
    event TokensSwept(address indexed to, uint256 amount);

    /**
     * @param _token Address of the ERC20 token to be vested
     * @param _updater Address that can update user allocations (granted UPDATER_ROLE)
     * @param _pauser Address that can pause/unpause the contract (granted PAUSER_ROLE)
     */
    constructor(IERC20 _token, address _updater, address _pauser) {
        token = _token;
        _grantRole(UPDATER_ROLE, _updater);
        _grantRole(PAUSER_ROLE, _pauser);
    }

    /**
     * @notice Releases all currently vested tokens for the caller
     * @dev Calculates the releasable amount and transfers tokens to the caller
     */
    function release() external whenNotPaused {
        require(allocationLocked, "Allocations are not locked");
        address user = msg.sender;
        uint256 amount = releasable(user);
        require(amount > 0, "No tokens to release");

        released[user] += amount;
        totalReleased += amount;

        token.safeTransfer(user, amount);
        emit TokensReleased(user, amount);
    }

    /**
     * @notice Calculates the amount of tokens that can be released for a user
     * @param _user Address of the user to check
     * @return releasableAmount of tokens available for release
     */
    function releasable(address _user) public view returns (uint256 releasableAmount) {
        return vestingSchedule(_user) - released[_user];
    }

    /**
     * @notice Gets the current vested amount for a user based on the current block timestamp
     * @param _user Address of the user to check
     * @return vestedAmount Total amount of tokens vested for the user at current time
     */
    function vestingSchedule(address _user) public view returns (uint256 vestedAmount) {
        return vestingSchedule(_user, block.timestamp);
    }

    /**
     * @notice Gets the vested amount for a user at a specific timestamp
     * @param _user Address of the user to check
     * @param _timestamp Timestamp to calculate vesting for
     * @return vestedAmount Total amount of tokens vested for the user at the given timestamp
     */
    function vestingSchedule(address _user, uint256 _timestamp) public view returns (uint256 vestedAmount) {
        return vestingSchedule(allocations[_user], _timestamp);
    }

    /**
     * @notice Calculates the vested amount for a given allocation at a specific timestamp
     * @dev Implements a vesting schedule with initial unlock + linear vesting:
     *      - Before vesting starts: 0 tokens vested
     *      - At vesting start: initVestedBps% immediately available
     *      - During vesting: Linear release of remaining tokens over vestingDuration
     *      - After vesting ends: 100% of allocation available
     *
     * @param _totalAmount Total allocation amount to calculate vesting for
     * @param _timestamp Timestamp to calculate vesting at
     * @return vestedAmount Amount of tokens vested at the given timestamp
     */
    function vestingSchedule(uint256 _totalAmount, uint256 _timestamp) public view returns (uint256 vestedAmount) {
        require(vestingStartTime > 0 && vestingDuration > 0, "Vesting parameters not set");

        if (_timestamp < vestingStartTime) {
            // Before the vesting period begins, no tokens are available
            return 0;
        } else if (_timestamp >= vestingStartTime + vestingDuration) {
            // After the vesting period ends, all tokens are fully vested
            return _totalAmount;
        } else {
            // During the vesting period: initial vesting + linear progression

            // Calculate the immediate vesting amount (percentage of total)
            uint256 initial = (_totalAmount * initVestedBps) / BPS_DENOMINATOR;
            // Calculate the amount subject to linear vesting
            uint256 remaining = _totalAmount - initial;
            // Calculate how much time has passed since vesting started
            uint256 elapsed = _timestamp - vestingStartTime;
            // Calculate the linear portion vested based on elapsed time
            // Formula: (remaining_amount * time_elapsed) / total_vesting_duration
            uint256 linearVested = (remaining * elapsed) / vestingDuration;
            // Total vested = initial immediate vesting + linear vested amount
            return initial + linearVested;
        }
    }

    /**
     * @notice Retrieves comprehensive vesting information for a user
     * @param _user Address of the user to query
     * @return allocationAmount Total allocation assigned to the user
     * @return releasedAmount Total amount of tokens already released to the user
     * @return vestedAmount Total amount of tokens vested for the user at current time
     * @return releasableAmount Amount of tokens currently available for release to the user
     */
    function userVestingInfo(address _user)
        external
        view
        returns (uint256 allocationAmount, uint256 releasedAmount, uint256 vestedAmount, uint256 releasableAmount)
    {
        return (allocations[_user], released[_user], vestingSchedule(_user), releasable(_user));
    }

    /**
     * @notice Returns the signed gap between contract balance and aggregate releasable now
     * @dev fundingGap = token.balanceOf(this) - (vestingSchedule(totalAllocation, now) - totalReleased).
     *      Positive value means surplus (enough to satisfy all immediate releases);
     *      negative means deficit (top-up needed to avoid reverts).
     */
    function fundingGap() public view returns (int256) {
        uint256 totalReleasable = vestingSchedule(totalAllocation, block.timestamp) - totalReleased;
        uint256 balance = address(token) == address(0) ? 0 : token.balanceOf(address(this));
        return int256(balance) - int256(totalReleasable);
    }

    /**
     * @notice Sets the vesting parameters for the contract
     * @param _initVestedBps Initial vested percentage in basis points (e.g., 1000 = 10%)
     * @param _vestingStartTime Timestamp when vesting begins
     * @param _vestingDuration Duration of the linear vesting period in seconds
     */
    function setVestingParameters(uint256 _initVestedBps, uint256 _vestingStartTime, uint256 _vestingDuration)
        external
        onlyOwner
    {
        require(!allocationLocked, "Allocations locked");
        require(_initVestedBps <= BPS_DENOMINATOR, "Initial vested BPS exceeds 100%");
        require(_vestingStartTime > 0, "Vesting start time must be greater than zero");
        require(_vestingDuration > 0, "Vesting duration must be greater than zero");

        initVestedBps = _initVestedBps;
        vestingStartTime = _vestingStartTime;
        vestingDuration = _vestingDuration;
        emit VestingParametersSet(_initVestedBps, _vestingStartTime, _vestingDuration);
    }

    /**
     * @notice Sets the token address for the vesting contract
     * @param _token Address of the token to be used for vesting
     */
    function setToken(IERC20 _token) external onlyOwner {
        require(!allocationLocked, "Allocations locked");
        require(address(token) == address(0), "Token already set");
        require(address(_token) != address(0), "Invalid token address");
        token = _token;
        emit TokenSet(address(_token));
    }

    /**
     * @notice Emergency function to sweep tokens from the contract
     * @dev This is an emergency function to recover tokens in case of critical issues
     * @param _to Address to send the tokens to
     * @param _amount Amount of tokens to sweep
     */
    function sweepTokens(address _to, uint256 _amount) external onlyOwner whenPaused {
        require(_to != address(0), "invalid recipient");
        require(_amount > 0, "amount must be greater than 0");

        require(_amount <= token.balanceOf(address(this)), "insufficient balance");
        token.safeTransfer(_to, _amount);
        emit TokensSwept(_to, _amount);
    }
}
