// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/TokenVesting.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Test Token", "TEST") {
        _mint(msg.sender, 100000000e18); // 100M tokens
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract IntegrationTest is Test {
    TokenVesting public vesting;
    MockToken public token;

    address public owner;
    address public updater;
    address public pauser;

    // Test beneficiaries
    address[] public beneficiaries;
    uint256[] public beneficiaryAllocations;

    uint256 public constant INIT_VESTED_BPS = 1000; // 10%
    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public vestingStartTime;

    function setUp() public {
        owner = address(this);
        updater = makeAddr("updater");
        pauser = makeAddr("pauser");

        token = new MockToken();
        vesting = new TokenVesting(IERC20(token), updater, pauser);

        vestingStartTime = block.timestamp + 1 days;
        vesting.setVestingParameters(INIT_VESTED_BPS, vestingStartTime, VESTING_DURATION);

        // Setup test beneficiaries and allocations
        _setupTestBeneficiaries();

        // Transfer sufficient tokens to vesting contract
        uint256 totalNeeded = _getTotalAllocations();
        token.transfer(address(vesting), totalNeeded);
    }

    function _setupTestBeneficiaries() internal {
        beneficiaries = new address[](4);
        beneficiaryAllocations = new uint256[](4);

        beneficiaries[0] = makeAddr("alice");
        beneficiaries[1] = makeAddr("bob");
        beneficiaries[2] = makeAddr("charlie");
        beneficiaries[3] = makeAddr("david");

        beneficiaryAllocations[0] = 10000e18; // 10k tokens
        beneficiaryAllocations[1] = 20000e18; // 20k tokens
        beneficiaryAllocations[2] = 30000e18; // 30k tokens
        beneficiaryAllocations[3] = 40000e18; // 40k tokens
    }

    function _getTotalAllocations() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < beneficiaryAllocations.length; i++) {
            total += beneficiaryAllocations[i];
        }
        return total;
    }

    function _sortAddresses() internal view returns (address[] memory, uint256[] memory) {
        address[] memory sortedBeneficiaries = new address[](beneficiaries.length);
        uint256[] memory sortedAllocations = new uint256[](beneficiaries.length);

        // Simple bubble sort for test data
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            sortedBeneficiaries[i] = beneficiaries[i];
            sortedAllocations[i] = beneficiaryAllocations[i];
        }

        for (uint256 i = 0; i < sortedBeneficiaries.length - 1; i++) {
            for (uint256 j = 0; j < sortedBeneficiaries.length - i - 1; j++) {
                if (sortedBeneficiaries[j] > sortedBeneficiaries[j + 1]) {
                    // Swap addresses
                    address tempBeneficiary = sortedBeneficiaries[j];
                    sortedBeneficiaries[j] = sortedBeneficiaries[j + 1];
                    sortedBeneficiaries[j + 1] = tempBeneficiary;

                    // Swap corresponding allocations
                    uint256 tempAlloc = sortedAllocations[j];
                    sortedAllocations[j] = sortedAllocations[j + 1];
                    sortedAllocations[j + 1] = tempAlloc;
                }
            }
        }

        return (sortedBeneficiaries, sortedAllocations);
    }

    // ============ Basic Integration Tests ============

    function test_CompleteVestingWorkflow() public {
        (address[] memory sortedBeneficiaries, uint256[] memory sortedAllocations) = _sortAddresses();

        // Step 1: Set allocations
        vm.prank(updater);
        vesting.setAllocations(sortedBeneficiaries, sortedAllocations);

        // Step 2: Lock allocations
        vm.prank(updater);
        vesting.lockAllocations();

        // Step 3: Test release at vesting start (initial vesting)
        vm.warp(vestingStartTime);
        vm.prank(sortedBeneficiaries[0]);
        vesting.release();

        uint256 expectedInitialRelease = (sortedAllocations[0] * INIT_VESTED_BPS) / vesting.BPS_DENOMINATOR();
        assertEq(vesting.released(sortedBeneficiaries[0]), expectedInitialRelease);
        assertEq(token.balanceOf(sortedBeneficiaries[0]), expectedInitialRelease);

        // Step 4: Test release at 50% vesting completion
        vm.warp(vestingStartTime + VESTING_DURATION / 2);

        vm.prank(sortedBeneficiaries[1]);
        vesting.release();

        // At 50% completion: initial vesting (10%) + 50% of linear vesting
        // For sortedBeneficiaries[1] (alice with 10,000e18):
        // Initial: 1,000e18, Linear remaining: 9,000e18
        // At 50%: 1,000e18 + 4,500e18 = 5,500e18
        uint256 initialVesting = (sortedAllocations[1] * INIT_VESTED_BPS) / vesting.BPS_DENOMINATOR();
        uint256 linearPortion = sortedAllocations[1] - initialVesting;
        uint256 expectedHalfwayRelease = initialVesting + (linearPortion / 2);
        assertEq(vesting.released(sortedBeneficiaries[1]), expectedHalfwayRelease);
        assertEq(token.balanceOf(sortedBeneficiaries[1]), expectedHalfwayRelease);

        // Step 5: Test full vesting completion
        vm.warp(vestingStartTime + VESTING_DURATION);

        vm.prank(sortedBeneficiaries[2]);
        vesting.release();

        assertEq(vesting.released(sortedBeneficiaries[2]), sortedAllocations[2]);
        assertEq(token.balanceOf(sortedBeneficiaries[2]), sortedAllocations[2]);
    }

    // ============ Allocation Management Tests ============

    function test_AllocationManagement() public {
        (address[] memory sortedBeneficiaries, uint256[] memory sortedAllocations) = _sortAddresses();

        // Set initial allocations
        vm.prank(updater);
        vesting.setAllocations(sortedBeneficiaries, sortedAllocations);

        // Verify allocations were set correctly
        for (uint256 i = 0; i < sortedBeneficiaries.length; i++) {
            assertEq(vesting.allocations(sortedBeneficiaries[i]), sortedAllocations[i]);
        }
        assertEq(vesting.totalAllocation(), _getTotalAllocations());

        // Add new beneficiaries
        address[] memory newBeneficiaries = new address[](1);
        uint256[] memory newAllocations = new uint256[](1);
        newBeneficiaries[0] = makeAddr("newBeneficiary");
        newAllocations[0] = 5000e18;

        vm.prank(updater);
        vesting.setAllocations(newBeneficiaries, newAllocations);

        assertEq(vesting.allocations(newBeneficiaries[0]), newAllocations[0]);
        assertEq(vesting.totalAllocation(), _getTotalAllocations() + newAllocations[0]);
    }

    // ============ Large Scale Tests ============

    function test_LargeScaleAllocation() public {
        uint256 numBeneficiaries = 1000;
        address[] memory largeBeneficiarySet = new address[](numBeneficiaries);
        uint256[] memory largeAllocations = new uint256[](numBeneficiaries);

        for (uint256 i = 0; i < numBeneficiaries; i++) {
            largeBeneficiarySet[i] = address(uint160(0x1000 + i)); // Sequential addresses for consistency
            largeAllocations[i] = 100e18; // 100 tokens each
        }

        // Create fresh vesting contract to avoid confusion with existing allocations
        TokenVesting freshVesting = new TokenVesting(IERC20(token), updater, pauser);
        freshVesting.setVestingParameters(INIT_VESTED_BPS, vestingStartTime, VESTING_DURATION);

        // Need tokens for this test
        uint256 neededTokens = numBeneficiaries * 100e18;
        token.mint(address(freshVesting), neededTokens);

        // Test large scale allocation
        vm.prank(updater);
        freshVesting.setAllocations(largeBeneficiarySet, largeAllocations);

        // Verify total allocation
        assertEq(freshVesting.totalAllocation(), neededTokens);

        // Test random beneficiary allocation
        uint256 randomIndex = 42;
        assertEq(freshVesting.allocations(largeBeneficiarySet[randomIndex]), 100e18);
    }

    // ============ Security and Edge Case Tests ============

    function test_MultipleUpdatesAndReleases() public {
        (address[] memory sortedBeneficiaries, uint256[] memory sortedAllocations) = _sortAddresses();

        // Initial allocation
        vm.prank(updater);
        vesting.setAllocations(sortedBeneficiaries, sortedAllocations);

        // Update beneficiary allocation before locking
        address[] memory updateBeneficiary = new address[](1);
        uint256[] memory updateAllocation = new uint256[](1);
        updateBeneficiary[0] = sortedBeneficiaries[0];
        updateAllocation[0] = sortedAllocations[0] * 2; // Double allocation

        vm.prank(updater);
        vesting.setAllocations(updateBeneficiary, updateAllocation);

        assertEq(vesting.allocations(sortedBeneficiaries[0]), updateAllocation[0]);

        // Lock and test vesting
        vm.prank(updater);
        vesting.lockAllocations();

        vm.warp(vestingStartTime + VESTING_DURATION);

        vm.prank(sortedBeneficiaries[0]);
        vesting.release();

        assertEq(vesting.released(sortedBeneficiaries[0]), updateAllocation[0]);
        assertEq(token.balanceOf(sortedBeneficiaries[0]), updateAllocation[0]);
    }

    function test_EmergencyPauseAndResume() public {
        (address[] memory sortedBeneficiaries, uint256[] memory sortedAllocations) = _sortAddresses();

        vm.prank(updater);
        vesting.setAllocations(sortedBeneficiaries, sortedAllocations);

        vm.prank(updater);
        vesting.lockAllocations();

        // Pause the contract
        vm.prank(pauser);
        vesting.pause();

        // Releases should fail when paused
        vm.warp(vestingStartTime + VESTING_DURATION);
        vm.expectRevert();
        vm.prank(sortedBeneficiaries[0]);
        vesting.release();

        // Resume and test release works
        vm.prank(pauser);
        vesting.unpause();

        vm.prank(sortedBeneficiaries[0]);
        vesting.release();
        assertEq(vesting.released(sortedBeneficiaries[0]), sortedAllocations[0]);
    }

    function test_TokenSweeping() public {
        // Setup allocations and lock
        (address[] memory sortedBeneficiaries, uint256[] memory sortedAllocations) = _sortAddresses();

        vm.prank(updater);
        vesting.setAllocations(sortedBeneficiaries, sortedAllocations);

        vm.prank(updater);
        vesting.lockAllocations();

        // Add extra tokens to contract
        uint256 extraTokens = 10000e18;
        token.mint(address(vesting), extraTokens);

        // Pause contract (required for sweeping)
        vm.prank(pauser);
        vesting.pause();

        // Sweep excess tokens
        address sweepRecipient = makeAddr("treasury");
        uint256 balanceBeforeSweep = token.balanceOf(sweepRecipient);

        vm.prank(owner);
        vesting.sweepTokens(sweepRecipient, extraTokens);

        assertEq(token.balanceOf(sweepRecipient), balanceBeforeSweep + extraTokens);

        // Resume contract and ensure vesting still works normally
        vm.prank(pauser);
        vesting.unpause();

        vm.warp(vestingStartTime + VESTING_DURATION);
        vm.prank(sortedBeneficiaries[0]);
        vesting.release();

        assertEq(vesting.released(sortedBeneficiaries[0]), sortedAllocations[0]);
    }
}
