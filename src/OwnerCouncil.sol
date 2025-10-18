// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@security/governance/simple-council/SimpleAdminCouncil.sol";

/**
 * @title OwnerCouncil
 * @notice SimpleAdminCouncil-based governor that can execute arbitrary external calls approved by voters.
 * @dev Its primary purpose is to hold ownership of a TokenVesting contract and execute its owner-only actions
 *      (setVestingParameters, setToken, recoverERC20, sweepTokens) and manage roles (UPDATER_ROLE, PAUSER_ROLE).
 *      Configure voters, number of required yes votes, and proposal active period in the constructor.
 */
contract OwnerCouncil is SimpleAdminCouncil {
    // Initializes the council with the provided voter addresses, required yes votes, and proposal active period
    constructor(address[] memory _voters, uint256 _requiredYesVotes, uint256 _activePeriod)
        SimpleAdminCouncil(_voters, _requiredYesVotes, _activePeriod)
    {}

    event SetVestingParametersProposed(
        uint256 proposalId, uint256 initBps, uint256 startTime, uint256 duration, uint256 granularitySeconds
    );
    event SetTokenProposed(uint256 proposalId, address newToken);
    event RecoverErc20Proposed(uint256 proposalId, address token, address to, uint256 amount);
    event SweepTokensProposed(uint256 proposalId, address to, uint256 amount);

    // Propose updating vesting parameters on a TokenVesting contract
    function proposeSetVestingParameters(
        address _target,
        uint256 _initBps,
        uint256 _startTime,
        uint256 _duration,
        uint256 _granularitySeconds
    ) external returns (uint256 proposalId) {
        bytes memory data = abi.encodeWithSelector(
            ITokenVesting.setVestingParameters.selector, _initBps, _startTime, _duration, _granularitySeconds
        );
        proposalId = createProposal(_target, data);
        emit SetVestingParametersProposed(proposalId, _initBps, _startTime, _duration, _granularitySeconds);
    }

    // Propose setting the vesting token on a TokenVesting contract
    function proposeSetToken(address _target, address _newToken) external returns (uint256 proposalId) {
        bytes memory data = abi.encodeWithSelector(ITokenVesting.setToken.selector, _newToken);
        proposalId = createProposal(_target, data);
        emit SetTokenProposed(proposalId, _newToken);
    }

    // Propose recovering any ERC20 tokens from TokenVesting contract
    function proposeRecoverERC20(address _target, address _erc20, address _to, uint256 _amount)
        external
        returns (uint256 proposalId)
    {
        bytes memory data = abi.encodeWithSelector(ITokenVesting.recoverERC20.selector, _erc20, _to, _amount);
        proposalId = createProposal(_target, data);
        emit RecoverErc20Proposed(proposalId, _erc20, _to, _amount);
    }

    // Propose sweeping vesting tokens while the TokenVesting contract is paused
    function proposeSweepTokens(address _target, address _to, uint256 _amount) external returns (uint256 proposalId) {
        bytes memory data = abi.encodeWithSelector(ITokenVesting.sweepTokens.selector, _to, _amount);
        proposalId = createProposal(_target, data);
        emit SweepTokensProposed(proposalId, _to, _amount);
    }
}

// Minimal interface for TokenVesting owner-only functions to avoid heavy imports
interface ITokenVesting {
    function setVestingParameters(uint256, uint256, uint256, uint256) external;
    function setToken(address) external;
    function recoverERC20(address, address, uint256) external;
    function sweepTokens(address, uint256) external;
}
