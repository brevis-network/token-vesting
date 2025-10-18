// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/TokenVesting.sol";
import "../src/OwnerCouncil.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OwnerCouncilTest is Test {
    OwnerCouncil council;
    TokenVesting vesting;
    MockToken token;

    address voter1;
    address voter2;
    address voter3;

    address updater;
    address pauser;

    function setUp() public {
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        voter3 = makeAddr("voter3");

        updater = makeAddr("updater");
        pauser = makeAddr("pauser");

        address[] memory voters = new address[](3);
        voters[0] = voter1;
        voters[1] = voter2;
        voters[2] = voter3;
        // Require 2 yes votes and 1-day active period
        council = new OwnerCouncil(voters, 2, 86400);

        token = new MockToken();
        vesting = new TokenVesting(IERC20(address(token)), updater, pauser);
        // Hand over ownership to the council so proposals can execute owner-only functions
        vesting.transferOwnership(address(council));
    }

    function _reachQuorumAndExecute(uint256 proposalId, bytes memory data) internal {
        // voter2 votes yes
        vm.prank(voter2);
        council.voteProposal(proposalId, true);
        // voter3 executes (auto-votes yes) with matching target+data
        vm.prank(voter3);
        council.executeProposal(proposalId, address(vesting), data);
    }

    function test_Propose_SetVestingParameters_and_Execute() public {
        // Voters propose setVestingParameters on vesting
        uint256 initBps = 1000; // 10%
        uint256 startTime = block.timestamp + 100;
        uint256 duration = 365 days;
        uint256 granularity = 86400; // daily

        bytes memory data = abi.encodeWithSelector(
            ITokenVesting.setVestingParameters.selector, initBps, startTime, duration, granularity
        );

        vm.prank(voter1);
        uint256 pid = council.proposeSetVestingParameters(address(vesting), initBps, startTime, duration, granularity);
        _reachQuorumAndExecute(pid, data);

        (uint256 bps, uint256 st, uint256 dur, uint256 g) = vesting.getVestingParameters();
        assertEq(bps, initBps);
        assertEq(st, startTime);
        assertEq(dur, duration);
        assertEq(g, granularity);
    }

    function test_Propose_SetToken_and_Execute() public {
        // Deploy a fresh vesting with zero token to allow setToken
        TokenVesting v2 = new TokenVesting(IERC20(address(0)), updater, pauser);
        v2.transferOwnership(address(council));
        bytes memory data = abi.encodeWithSelector(ITokenVesting.setToken.selector, address(token));

        vm.prank(voter1);
        uint256 pid = council.proposeSetToken(address(v2), address(token));
        // reach quorum and execute
        vm.prank(voter2);
        council.voteProposal(pid, true);
        vm.prank(voter3);
        council.executeProposal(pid, address(v2), data);

        assertEq(address(v2.token()), address(token));
    }

    function test_Propose_RecoverERC20_and_Execute() public {
        // Send stray token to vesting (not the vesting token)
        MockToken stray = new MockToken();
        stray.mint(address(vesting), 1000e18);

        address treasury = makeAddr("treasury");
        bytes memory data =
            abi.encodeWithSelector(ITokenVesting.recoverERC20.selector, address(stray), treasury, 500e18);

        vm.prank(voter1);
        uint256 pid = council.proposeRecoverERC20(address(vesting), address(stray), treasury, 500e18);
        _reachQuorumAndExecute(pid, data);

        assertEq(stray.balanceOf(treasury), 500e18);
        assertEq(stray.balanceOf(address(vesting)), 500e18);
    }

    function test_Propose_SweepTokens_and_Execute() public {
        // Lock allocations and pause to allow sweep
        address[] memory bs = new address[](1);
        uint256[] memory as_ = new uint256[](1);
        bs[0] = makeAddr("alice");
        as_[0] = 100e18;
        vm.prank(updater);
        vesting.setAllocations(bs, as_);
        // As owner is the council, lock via council by temporarily transferring ownership for setup is already done.
        // Call lockAllocations as owner by prank to council address.
        vm.prank(address(council));
        vesting.lockAllocations();

        // Fund vesting with vesting token
        token.mint(address(vesting), 1000e18);

        // Pause via pauser role
        vm.prank(pauser);
        vesting.pause();

        address treasury = makeAddr("treasury2");
        bytes memory data = abi.encodeWithSelector(ITokenVesting.sweepTokens.selector, treasury, 400e18);

        vm.prank(voter1);
        uint256 pid = council.proposeSweepTokens(address(vesting), treasury, 400e18);
        _reachQuorumAndExecute(pid, data);

        assertEq(token.balanceOf(treasury), 400e18);
    }

    function test_Proposal_Expires_When_ActivePeriod_Passed() public {
        // Create a proposal then move time beyond ActivePeriod to fail execution
        bytes memory data = abi.encodeWithSelector(ITokenVesting.setVestingParameters.selector, 0, 1, 1, 1);
        vm.prank(voter1);
        uint256 pid = council.proposeSetVestingParameters(address(vesting), 0, 1, 1, 1);

        // warp beyond SimpleCouncil.ActivePeriod (86400)
        vm.warp(block.timestamp + 86401);

        vm.prank(voter2);
        vm.expectRevert();
        council.executeProposal(pid, address(vesting), data);
    }

    function test_Propose_LockAllocations_and_Execute() public {
        // Prepare a simple allocation
        address[] memory bs = new address[](1);
        uint256[] memory as_ = new uint256[](1);
        bs[0] = makeAddr("bob");
        as_[0] = 123e18;
        vm.prank(updater);
        vesting.setAllocations(bs, as_);

        // Propose and execute lockAllocations via council
        bytes memory data = abi.encodeWithSelector(ITokenVesting.lockAllocations.selector);
        vm.prank(voter1);
        uint256 pid = council.proposeLockAllocations(address(vesting));
        _reachQuorumAndExecute(pid, data);

        // Allocations should be locked
        assertTrue(vesting.allocationLocked());

        // Further updates should revert
        as_[0] = 456e18;
        vm.prank(updater);
        vm.expectRevert(bytes("Allocations are locked"));
        vesting.setAllocations(bs, as_);
    }
}
