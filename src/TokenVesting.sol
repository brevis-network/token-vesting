// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
 * - Configuration before beneficiary claims:
 *   1) Owner sets vesting parameters via {setVestingParameters} (init bps, start time, duration).
 *   2) Updater sets/updates beneficiary allocations via {setAllocations}.
 *   3) Lock allocations via {lockAllocations}. After locking:
 *      - {setAllocations}, {setVestingParameters}, and {setToken} are no longer callable.
 *      - Beneficiaries can start calling {release} once vesting has started.
 *   4) Fund the contract with the vesting token so it can cover upcoming releases (not enforced on-chain).
 *
 * - Claiming: Beneficiaries call {release} when not paused. It transfers the currently vested, unreleased amount.
 * - Pausing/Emergency: Accounts with PAUSER_ROLE can pause/unpause; when paused, {release} is disabled,
 *   and the owner can rescue the vesting token via {sweepTokens}.
 * @author Brevis Network
 */
contract TokenVesting is TokenAllocation, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Denominator for basis points calculations (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10000;

    IERC20 public token; // standard (no fees/rebases) token being vested

    mapping(address => uint256) public released; // Mapping from beneficiary address to their released tokens
    uint256 public totalReleased; // Total tokens released across all beneficiaries

    uint256 public initVestedBps; // Initial vested percentage in basis points (e.g., 1000 = 10.00%)
    uint256 public vestingStartTime; // Timestamp when the vesting period starts
    uint256 public vestingDuration; // Duration of the linear vesting period in seconds
    uint256 public vestingGranularity = 1; // Step size in seconds for linear accrual (e.g., 86400 for daily). Defaults to 1.

    mapping(address => bool) public beneficiaryPaused; // When true, the beneficiary cannot release vested tokens

    event TokensReleased(address indexed beneficiary, uint256 amount);
    event VestingParametersSet(
        uint256 initVestedBps, uint256 vestingStartTime, uint256 vestingDuration, uint256 vestingGranularity
    );
    event TokenSet(address indexed token);
    event TokensSwept(address indexed to, uint256 amount);
    event BeneficiaryPauseSet(address indexed beneficiary, bool paused);

    /**
     * @param _token Address of the ERC20 token to be vested
     * @param _updater Address that can update beneficiary allocations (granted UPDATER_ROLE if non-zero; zero defers assignment)
     * @param _pauser Address that can pause/unpause the contract (granted PAUSER_ROLE if non-zero; zero defers assignment)
     */
    constructor(IERC20 _token, address _updater, address _pauser) {
        token = _token;
        if (_updater != address(0)) {
            _grantRole(UPDATER_ROLE, _updater);
        }
        if (_pauser != address(0)) {
            _grantRole(PAUSER_ROLE, _pauser);
        }
    }

    /**
     * @notice Releases all currently vested tokens for the caller
     */
    function release() external whenNotPaused {
        _release(msg.sender);
    }

    /**
     * @notice Releases all currently vested tokens for a specified beneficiary
     * @dev Only callable by the UPDATER_ROLE
     * @param _beneficiary Address of the beneficiary to release tokens for
     */
    function release(address _beneficiary) external whenNotPaused onlyRole(UPDATER_ROLE) {
        _release(_beneficiary);
    }

    /**
     * @notice Internal function to handle the release of vested tokens to a beneficiary
     * @dev Calculates the releasable amount and transfers tokens to the caller
     * @param _beneficiary Address of the beneficiary to release tokens for
     */
    function _release(address _beneficiary) internal nonReentrant {
        require(allocationLocked, "Allocations are not locked");
        require(!beneficiaryPaused[_beneficiary], "Beneficiary is paused");
        uint256 amount = releasable(_beneficiary);
        require(amount > 0, "No tokens to release");

        released[_beneficiary] += amount;
        totalReleased += amount;

        token.safeTransfer(_beneficiary, amount);
        emit TokensReleased(_beneficiary, amount);
    }

    /**
     * @notice Calculates the amount of tokens that can be released for a beneficiary
     * @param _beneficiary Address of the beneficiary to check
     * @return releasableAmount of tokens available for release
     */
    function releasable(address _beneficiary) public view returns (uint256 releasableAmount) {
        return vestingSchedule(_beneficiary) - released[_beneficiary];
    }

    /**
     * @notice Gets the current vested amount for a beneficiary based on the current block timestamp
     * @param _beneficiary Address of the beneficiary to check
     * @return vestedAmount Total amount of tokens vested for the beneficiary at current time
     */
    function vestingSchedule(address _beneficiary) public view returns (uint256 vestedAmount) {
        return vestingSchedule(_beneficiary, block.timestamp);
    }

    /**
     * @notice Gets the vested amount for a beneficiary at a specific timestamp
     * @param _beneficiary Address of the beneficiary to check
     * @param _timestamp Timestamp to calculate vesting for
     * @return vestedAmount Total amount of tokens vested for the beneficiary at the given timestamp
     */
    function vestingSchedule(address _beneficiary, uint256 _timestamp) public view returns (uint256 vestedAmount) {
        return vestingSchedule(allocations[_beneficiary], _timestamp);
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
            // During the vesting period: initial vesting + stepwise linear progression

            // Calculate the immediate vesting amount (percentage of total)
            uint256 initial = (_totalAmount * initVestedBps) / BPS_DENOMINATOR;
            // Calculate the amount subject to linear vesting
            uint256 remaining = _totalAmount - initial;
            // Calculate how much time has passed since vesting started
            uint256 elapsed = _timestamp - vestingStartTime;
            // Determine steps total using ceil division to ensure final boundary vests all
            uint256 g = vestingGranularity;
            uint256 stepsTotal = (vestingDuration + g - 1) / g; // ceil(vestingDuration / g)
            // Steps elapsed so far (floor)
            uint256 stepsElapsed = elapsed / g;
            if (stepsElapsed > stepsTotal) stepsElapsed = stepsTotal;
            // Linear vested based on completed steps
            uint256 linearVested = (remaining * stepsElapsed) / stepsTotal;
            // Total vested = initial immediate vesting + stepwise linear vested amount
            return initial + linearVested;
        }
    }

    /**
     * @notice Retrieves comprehensive vesting information for a beneficiary
     * @param _beneficiary Address of the beneficiary to query
     * @return allocationAmount Total allocation assigned to the beneficiary
     * @return releasedAmount Total amount of tokens already released to the beneficiary
     * @return vestedAmount Total amount of tokens vested for the beneficiary at current time
     * @return releasableAmount Amount of tokens currently available for release to the beneficiary
     */
    function beneficiaryVestingInfo(address _beneficiary)
        external
        view
        returns (uint256 allocationAmount, uint256 releasedAmount, uint256 vestedAmount, uint256 releasableAmount)
    {
        return
            (allocations[_beneficiary], released[_beneficiary], vestingSchedule(_beneficiary), releasable(_beneficiary));
    }

    /**
     * @notice Returns the signed gap between contract balance and aggregate releasable now
     * @dev Equivalent to fundingGap(block.timestamp).
     *      Positive value means surplus (enough to satisfy all immediate releases);
     *      negative means deficit (top-up needed to avoid reverts).
     * @return gap Signed difference: balance - (aggregate releasable now)
     */
    function fundingGap() public view returns (int256 gap) {
        return fundingGap(block.timestamp);
    }

    /**
     * @notice Returns the signed gap between contract balance and aggregate releasable at a given timestamp
     * @dev Formula: gap = token.balanceOf(this) - (vestingSchedule(totalAllocation, _timestamp) - totalReleased).
     *      Positive means surplus at the provided timestamp; negative means deficit.
     * @param _timestamp The timestamp at which to evaluate aggregate vesting.
     * @return gap Signed difference: balance - (aggregate releasable at _timestamp)
     */
    function fundingGap(uint256 _timestamp) public view returns (int256 gap) {
        uint256 totalReleasable = vestingSchedule(totalAllocation, _timestamp) - totalReleased;
        uint256 balance = address(token) == address(0) ? 0 : token.balanceOf(address(this));
        return int256(balance) - int256(totalReleasable);
    }

    /**
     * @notice Sets the vesting parameters for the contract
     * @param _initVestedBps Initial vested percentage in basis points (e.g., 1000 = 10%)
     * @param _vestingStartTime Timestamp when vesting begins
     * @param _vestingDuration Duration of the linear vesting period in seconds
     * @param _granularitySeconds Step size in seconds for linear accrual (e.g., 86400 for daily)
     */
    function setVestingParameters(
        uint256 _initVestedBps,
        uint256 _vestingStartTime,
        uint256 _vestingDuration,
        uint256 _granularitySeconds
    ) external onlyOwner {
        require(!allocationLocked, "Allocations locked");
        require(_initVestedBps <= BPS_DENOMINATOR, "Initial vested BPS exceeds 100%");
        require(_vestingStartTime > 0, "Vesting start time must be greater than zero");
        require(_vestingDuration > 0, "Vesting duration must be greater than zero");
        require(_granularitySeconds > 0, "Granularity must be greater than zero");

        initVestedBps = _initVestedBps;
        vestingStartTime = _vestingStartTime;
        vestingDuration = _vestingDuration;
        vestingGranularity = _granularitySeconds;
        emit VestingParametersSet(_initVestedBps, _vestingStartTime, _vestingDuration, _granularitySeconds);
    }

    /**
     * @notice Set pause state for a specific beneficiary
     * @param _beneficiary Address of the beneficiary
     * @param _paused New pause state
     */
    function setBeneficiaryPaused(address _beneficiary, bool _paused) external onlyRole(PAUSER_ROLE) {
        require(_beneficiary != address(0), "invalid beneficiary");
        if (beneficiaryPaused[_beneficiary] == _paused) return;
        beneficiaryPaused[_beneficiary] = _paused;
        emit BeneficiaryPauseSet(_beneficiary, _paused);
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
     * @notice Allows the owner to recover any ERC20 tokens mistakenly sent to this contract
     * @param _erc20 Address of the ERC20 token to recover
     * @param _to Address to send the recovered tokens to
     * @param _amount Amount of tokens to recover
     */
    function recoverERC20(IERC20 _erc20, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "invalid recipient");
        require(_amount > 0, "amount must be greater than 0");
        require(address(_erc20) != address(token), "cannot recover vesting token");

        require(_amount <= _erc20.balanceOf(address(this)), "insufficient balance");
        _erc20.safeTransfer(_to, _amount);
    }

    /**
     * @notice Emergency function to sweep tokens from the contract
     * @dev This is an emergency function to recover vesting tokens in case of critical issues
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
