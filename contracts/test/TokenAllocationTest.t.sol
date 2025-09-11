// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TokenAllocation.sol";

// Test contract that extends TokenAllocation to make it non-abstract for testing
contract TestableTokenAllocation is TokenAllocation {
    constructor(address updater, address pauser) {
        _grantRole(UPDATER_ROLE, updater);
        _grantRole(PAUSER_ROLE, pauser);
    }
}

contract TokenAllocationTest is Test {
    TestableTokenAllocation public allocation;
    address public owner;
    address public updater;
    address public pauser;
    address public user1;
    address public user2;
    address public user3;

    event AllocationSet(address indexed user, uint256 allocation);
    event AllocationsLocked();

    function setUp() public {
        owner = address(this);
        updater = makeAddr("updater");
        pauser = makeAddr("pauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        allocation = new TestableTokenAllocation(updater, pauser);
    }

    // ============ Constructor Tests ============

    function test_InitialState() public view {
        assertEq(allocation.totalAllocation(), 0);
        assertFalse(allocation.allocationLocked());
        assertTrue(allocation.hasRole(allocation.UPDATER_ROLE(), updater));
        assertTrue(allocation.hasRole(allocation.PAUSER_ROLE(), pauser));
        assertEq(allocation.owner(), owner);
    }

    // ============ setUserAllocations Tests ============

    function test_SetUserAllocations_Success() public {
        address[] memory users = new address[](2);
        uint256[] memory allocations = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        allocations[0] = 1000e18;
        allocations[1] = 2000e18;

        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        assertEq(allocation.allocations(user1), 1000e18);
        assertEq(allocation.allocations(user2), 2000e18);
        assertEq(allocation.totalAllocation(), 3000e18);
    }

    function test_SetUserAllocations_UpdateExisting() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 1000e18;

        // Set initial allocation
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        // Update existing allocation
        allocations[0] = 2000e18;
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        assertEq(allocation.allocations(user1), 2000e18);
        assertEq(allocation.totalAllocation(), 2000e18);
    }

    function test_SetUserAllocations_RemoveUser() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 1000e18;

        // Set initial allocation
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        // Remove user by setting allocation to 0
        allocations[0] = 0;
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        assertEq(allocation.allocations(user1), 0);
        assertEq(allocation.totalAllocation(), 0);
    }

    function test_SetUserAllocations_NoChangeSkipped() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 1000e18;

        // Set initial allocation
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        // Set same allocation again - should not emit event
        vm.recordLogs();
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0); // No events should be emitted
    }

    function test_SetUserAllocations_RevertWhen_NotUpdater() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 1000e18;

        vm.expectRevert();
        vm.prank(user1);
        allocation.setUserAllocations(users, allocations);
    }

    function test_SetUserAllocations_RevertWhen_AllocationsLocked() public {
        vm.prank(updater);
        allocation.lockAllocations();

        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 1000e18;

        vm.expectRevert("Allocations are locked");
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);
    }

    function test_SetUserAllocations_RevertWhen_MismatchedLengths() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](2);
        users[0] = user1;
        allocations[0] = 1000e18;
        allocations[1] = 2000e18;

        vm.expectRevert("Mismatched input lengths");
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);
    }

    function test_SetUserAllocations_RevertWhen_Paused() public {
        vm.prank(pauser);
        allocation.pause();

        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 1000e18;

        vm.expectRevert(); // EnforcedPause() in newer OpenZeppelin versions
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);
    }

    // ============ lockAllocations Tests ============

    function test_LockAllocations_Success() public {
        vm.expectEmit(false, false, false, true);
        emit AllocationsLocked();

        // Test updater can lock
        vm.prank(updater);
        allocation.lockAllocations();
        assertTrue(allocation.allocationLocked());

        // Reset and test owner can lock
        allocation = new TestableTokenAllocation(updater, pauser);
        vm.expectEmit(false, false, false, true);
        emit AllocationsLocked();

        vm.prank(owner);
        allocation.lockAllocations();
        assertTrue(allocation.allocationLocked());
    }

    function test_LockAllocations_RevertWhen_NotAuthorized() public {
        vm.expectRevert("Not authorized");
        vm.prank(user1);
        allocation.lockAllocations();
    }

    function test_LockAllocations_RevertWhen_AlreadyLocked() public {
        vm.prank(updater);
        allocation.lockAllocations();

        vm.expectRevert("Allocations already locked");
        vm.prank(updater);
        allocation.lockAllocations();
    }

    // ============ Fuzz Tests ============

    function testFuzz_SetUserAllocations_Updates(address user, uint256 allocation1, uint256 allocation2) public {
        vm.assume(user != address(0));
        vm.assume(allocation1 != allocation2);

        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user;
        allocations[0] = allocation1;

        // Set initial allocation
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);
        assertEq(allocation.allocations(user), allocation1);

        // Update allocation
        allocations[0] = allocation2;
        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);
        assertEq(allocation.allocations(user), allocation2);
    }

    // ============ Edge Case Tests ============

    function test_EdgeCase_MaxUint256Allocation() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = type(uint256).max;

        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        assertEq(allocation.allocations(user1), type(uint256).max);
        assertEq(allocation.totalAllocation(), type(uint256).max);
    }

    function test_EdgeCase_ZeroAllocation() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 0;

        vm.prank(updater);
        allocation.setUserAllocations(users, allocations);

        assertEq(allocation.allocations(user1), 0);
        assertEq(allocation.totalAllocation(), 0);
    }
}
