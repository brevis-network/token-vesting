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
    address public beneficiary1;
    address public beneficiary2;
    address public beneficiary3;

    event AllocationSet(address indexed beneficiary, uint256 allocation);
    event TotalAllocationSet(uint256 totalAllocation);
    event AllocationsLocked();

    function setUp() public {
        owner = address(this);
        updater = makeAddr("updater");
        pauser = makeAddr("pauser");
        beneficiary1 = makeAddr("beneficiary1");
        beneficiary2 = makeAddr("beneficiary2");
        beneficiary3 = makeAddr("beneficiary3");

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

    // ============ setAllocations Tests ============

    function test_SetBeneficiaryAllocations_Success() public {
        address[] memory beneficiaries = new address[](2);
        uint256[] memory allocations = new uint256[](2);
        beneficiaries[0] = beneficiary1;
        beneficiaries[1] = beneficiary2;
        allocations[0] = 1000e18;
        allocations[1] = 2000e18;

        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        assertEq(allocation.allocations(beneficiary1), 1000e18);
        assertEq(allocation.allocations(beneficiary2), 2000e18);
        assertEq(allocation.totalAllocation(), 3000e18);
    }

    function test_SetBeneficiaryAllocations_UpdateExisting() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;

        // Set initial allocation
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        // Update existing allocation
        allocations[0] = 2000e18;
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        assertEq(allocation.allocations(beneficiary1), 2000e18);
        assertEq(allocation.totalAllocation(), 2000e18);
    }

    function test_SetBeneficiaryAllocations_RemoveBeneficiary() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;

        // Set initial allocation
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        // Remove beneficiary by setting allocation to 0
        allocations[0] = 0;
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        assertEq(allocation.allocations(beneficiary1), 0);
        assertEq(allocation.totalAllocation(), 0);
    }

    function test_SetBeneficiaryAllocations_NoChangeSkipped() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;

        // Set initial allocation
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        // Set same allocation again - should skip AllocationSet and only emit TotalAllocationSet
        vm.expectEmit(false, false, false, true);
        emit TotalAllocationSet(1000e18);
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);
    }

    function test_SetBeneficiaryAllocations_RevertWhen_NotUpdater() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;

        vm.expectRevert();
        vm.prank(beneficiary1);
        allocation.setAllocations(beneficiaries, allocations);
    }

    function test_SetBeneficiaryAllocations_RevertWhen_AllocationsLocked() public {
        vm.prank(updater);
        allocation.lockAllocations();

        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;

        vm.expectRevert("Allocations are locked");
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);
    }

    function test_SetBeneficiaryAllocations_RevertWhen_MismatchedLengths() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](2);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;
        allocations[1] = 2000e18;

        vm.expectRevert("Mismatched input lengths");
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);
    }

    function test_SetBeneficiaryAllocations_RevertWhen_Paused() public {
        vm.prank(pauser);
        allocation.pause();

        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 1000e18;

        vm.expectRevert(); // EnforcedPause() in newer OpenZeppelin versions
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);
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
        vm.prank(beneficiary1);
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

    function testFuzz_SetBeneficiaryAllocations_Updates(address beneficiary, uint256 allocation1, uint256 allocation2)
        public
    {
        vm.assume(beneficiary != address(0));
        vm.assume(allocation1 != allocation2);

        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary;
        allocations[0] = allocation1;

        // Set initial allocation
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);
        assertEq(allocation.allocations(beneficiary), allocation1);

        // Update allocation
        allocations[0] = allocation2;
        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);
        assertEq(allocation.allocations(beneficiary), allocation2);
    }

    // ============ Edge Case Tests ============

    function test_EdgeCase_MaxUint256Allocation() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = type(uint256).max;

        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        assertEq(allocation.allocations(beneficiary1), type(uint256).max);
        assertEq(allocation.totalAllocation(), type(uint256).max);
    }

    function test_EdgeCase_ZeroAllocation() public {
        address[] memory beneficiaries = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        beneficiaries[0] = beneficiary1;
        allocations[0] = 0;

        vm.prank(updater);
        allocation.setAllocations(beneficiaries, allocations);

        assertEq(allocation.allocations(beneficiary1), 0);
        assertEq(allocation.totalAllocation(), 0);
    }
}
