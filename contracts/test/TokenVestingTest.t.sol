// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/TokenVesting.sol";

// Mock ERC20 token for testing
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1000000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenVestingTest is Test {
    TokenVesting public vesting;
    MockToken public token;
    address public owner;
    address public updater;
    address public pauser;
    address public user1;
    address public user2;
    address public user3;

    uint256 public constant INIT_VESTED_BPS = 2000; // 20%
    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public vestingStartTime;

    event TokensReleased(address indexed user, uint256 amount);
    event VestingParametersSet(uint256 initVestedBps, uint256 vestingStartTime, uint256 vestingDuration);
    event TokenSet(address indexed token);
    event TokensSwept(address indexed to, uint256 amount);
    event AllocationSet(address indexed user, uint256 allocation);

    function setUp() public {
        owner = address(this);
        updater = makeAddr("updater");
        pauser = makeAddr("pauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        token = new MockToken();
        vesting = new TokenVesting(IERC20(token), updater, pauser);

        vestingStartTime = block.timestamp + 100; // Start in 100 seconds

        // Set up vesting parameters
        vesting.setVestingParameters(INIT_VESTED_BPS, vestingStartTime, VESTING_DURATION);

        // Transfer tokens to vesting contract
        token.transfer(address(vesting), 100000e18);
    }

    // ============ Constructor Tests ============

    function test_InitialState() public view {
        assertEq(address(vesting.token()), address(token));
        assertTrue(vesting.hasRole(vesting.UPDATER_ROLE(), updater));
        assertTrue(vesting.hasRole(vesting.PAUSER_ROLE(), pauser));
        assertEq(vesting.owner(), owner);
        assertEq(vesting.initVestedBps(), INIT_VESTED_BPS);
        assertEq(vesting.vestingStartTime(), vestingStartTime);
        assertEq(vesting.vestingDuration(), VESTING_DURATION);
        assertEq(vesting.totalReleased(), 0);
    }

    // ============ Allocation Setup Helper ============
    function _setupAllocations() internal {
        address[] memory users = new address[](3);
        uint256[] memory allocations = new uint256[](3);

        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        allocations[0] = 10000e18;
        allocations[1] = 20000e18;
        allocations[2] = 30000e18;

        vm.prank(updater);
        vesting.setUserAllocations(users, allocations);

        vm.prank(updater);
        vesting.lockAllocations();
    }

    // ============ setVestingParameters Tests ============

    function test_SetVestingParameters_Success() public {
        uint256 newInitVestedBps = 1500;
        uint256 newVestingStartTime = block.timestamp + 200;
        uint256 newVestingDuration = 730 days;

        vm.expectEmit(false, false, false, true);
        emit VestingParametersSet(newInitVestedBps, newVestingStartTime, newVestingDuration);

        vesting.setVestingParameters(newInitVestedBps, newVestingStartTime, newVestingDuration);

        assertEq(vesting.initVestedBps(), newInitVestedBps);
        assertEq(vesting.vestingStartTime(), newVestingStartTime);
        assertEq(vesting.vestingDuration(), newVestingDuration);
    }

    function test_SetVestingParameters_RevertWhen_NotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        vesting.setVestingParameters(1000, block.timestamp + 100, 365 days);
    }

    function test_SetVestingParameters_RevertWhen_AllocationsLocked() public {
        vm.prank(updater);
        vesting.lockAllocations();

        vm.expectRevert("Allocations locked");
        vesting.setVestingParameters(1000, block.timestamp + 100, 365 days);
    }

    function test_SetVestingParameters_RevertWhen_InvalidBPS() public {
        vm.expectRevert("Initial vested BPS exceeds 100%");
        vesting.setVestingParameters(10001, block.timestamp + 100, 365 days);
    }

    function test_SetVestingParameters_RevertWhen_ZeroStartTime() public {
        vm.expectRevert("Vesting start time must be greater than zero");
        vesting.setVestingParameters(1000, 0, 365 days);
    }

    function test_SetVestingParameters_RevertWhen_ZeroDuration() public {
        vm.expectRevert("Vesting duration must be greater than zero");
        vesting.setVestingParameters(1000, block.timestamp + 100, 0);
    }

    // ============ setToken Tests ============

    function test_SetToken_Success() public {
        // Deploy new vesting without token
        TokenVesting newVesting = new TokenVesting(IERC20(address(0)), updater, pauser);
        MockToken newToken = new MockToken();

        vm.expectEmit(true, false, false, false);
        emit TokenSet(address(newToken));

        newVesting.setToken(IERC20(newToken));
        assertEq(address(newVesting.token()), address(newToken));
    }

    function test_SetToken_RevertWhen_NotOwner() public {
        TokenVesting newVesting = new TokenVesting(IERC20(address(0)), updater, pauser);
        MockToken newToken = new MockToken();

        vm.expectRevert();
        vm.prank(user1);
        newVesting.setToken(IERC20(newToken));
    }

    function test_SetToken_RevertWhen_TokenAlreadySet() public {
        MockToken newToken = new MockToken();

        vm.expectRevert("Token already set");
        vesting.setToken(IERC20(newToken));
    }

    function test_SetToken_RevertWhen_AllocationsLocked() public {
        TokenVesting newVesting = new TokenVesting(IERC20(address(0)), updater, pauser);
        MockToken newToken = new MockToken();

        vm.prank(updater);
        newVesting.lockAllocations();

        vm.expectRevert("Allocations locked");
        newVesting.setToken(IERC20(newToken));
    }

    // ============ vestingSchedule Tests ============

    function test_VestingSchedule_BeforeVestingStart() public view {
        uint256 allocation = 10000e18;
        uint256 beforeStart = vestingStartTime - 1;

        uint256 vested = vesting.vestingSchedule(allocation, beforeStart);
        assertEq(vested, 0);
    }

    function test_VestingSchedule_AtVestingStart() public view {
        uint256 allocation = 10000e18;
        uint256 expected = (allocation * INIT_VESTED_BPS) / vesting.BPS_DENOMINATOR(); // 20%

        uint256 vested = vesting.vestingSchedule(allocation, vestingStartTime);
        assertEq(vested, expected);
    }

    function test_VestingSchedule_MidVesting() public view {
        uint256 allocation = 10000e18;
        uint256 midTime = vestingStartTime + (VESTING_DURATION / 2); // Halfway through

        uint256 initialVested = (allocation * INIT_VESTED_BPS) / vesting.BPS_DENOMINATOR(); // 20%
        uint256 remaining = allocation - initialVested; // 80%
        uint256 linearVested = remaining / 2; // Half of remaining
        uint256 expected = initialVested + linearVested; // 20% + 40% = 60%

        uint256 vested = vesting.vestingSchedule(allocation, midTime);
        assertEq(vested, expected);
    }

    function test_VestingSchedule_AfterVestingEnd() public view {
        uint256 allocation = 10000e18;
        uint256 afterEnd = vestingStartTime + VESTING_DURATION + 1;

        uint256 vested = vesting.vestingSchedule(allocation, afterEnd);
        assertEq(vested, allocation); // 100%
    }

    function test_VestingSchedule_ZeroInitialVesting() public {
        // Set up contract with 0% initial vesting
        vesting.setVestingParameters(0, vestingStartTime, VESTING_DURATION);

        uint256 allocation = 10000e18;
        uint256 atStart = vestingStartTime;
        uint256 midTime = vestingStartTime + (VESTING_DURATION / 2);

        assertEq(vesting.vestingSchedule(allocation, atStart), 0);
        assertEq(vesting.vestingSchedule(allocation, midTime), allocation / 2);
    }

    function test_VestingSchedule_FullInitialVesting() public {
        // Set up contract with 100% initial vesting
        vesting.setVestingParameters(10000, vestingStartTime, VESTING_DURATION);

        uint256 allocation = 10000e18;
        uint256 atStart = vestingStartTime;

        assertEq(vesting.vestingSchedule(allocation, atStart), allocation);
    }

    function test_VestingSchedule_RevertWhen_ParametersNotSet() public {
        TokenVesting newVesting = new TokenVesting(IERC20(token), updater, pauser);

        vm.expectRevert("Vesting parameters not set");
        newVesting.vestingSchedule(10000e18, block.timestamp);
    }

    function test_VestingSchedule_UserOverloads() public {
        _setupAllocations();

        uint256 currentVested = vesting.vestingSchedule(user1);
        uint256 timestampVested = vesting.vestingSchedule(user1, block.timestamp);

        assertEq(currentVested, timestampVested);
        assertEq(currentVested, vesting.vestingSchedule(vesting.allocations(user1), block.timestamp));
    }

    // ============ release Tests ============

    function test_Release_BeforeVestingStart() public {
        _setupAllocations();

        uint256 beforeStart = vestingStartTime - 1;
        vm.warp(beforeStart);

        vm.expectRevert("No tokens to release");
        vm.prank(user1);
        vesting.release();
    }

    function test_Release_AtVestingStart() public {
        _setupAllocations();
        vm.warp(vestingStartTime);

        uint256 allocation = vesting.allocations(user1);
        uint256 expectedRelease = (allocation * INIT_VESTED_BPS) / vesting.BPS_DENOMINATOR();
        uint256 balanceBefore = token.balanceOf(user1);

        vm.expectEmit(true, false, false, true);
        emit TokensReleased(user1, expectedRelease);

        vm.prank(user1);
        vesting.release();

        assertEq(token.balanceOf(user1), balanceBefore + expectedRelease);
        assertEq(vesting.released(user1), expectedRelease);
        assertEq(vesting.totalReleased(), expectedRelease);
    }

    function test_Release_MidVesting() public {
        _setupAllocations();
        uint256 midTime = vestingStartTime + (VESTING_DURATION / 4); // 25% through
        vm.warp(midTime);

        uint256 expectedVested = vesting.vestingSchedule(user1, midTime);
        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        vesting.release();

        assertEq(token.balanceOf(user1), balanceBefore + expectedVested);
        assertEq(vesting.released(user1), expectedVested);
    }

    function test_Release_MultipleReleases() public {
        _setupAllocations();
        vm.warp(vestingStartTime);

        // First release
        vm.prank(user1);
        vesting.release();
        uint256 firstRelease = vesting.released(user1);

        // Move time forward and release again
        vm.warp(vestingStartTime + (VESTING_DURATION / 2));
        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        vesting.release();

        uint256 totalReleased = vesting.released(user1);
        assertTrue(totalReleased > firstRelease);
        assertEq(token.balanceOf(user1), balanceBefore + (totalReleased - firstRelease));
    }

    function test_Release_FullVesting() public {
        _setupAllocations();
        vm.warp(vestingStartTime + VESTING_DURATION);

        uint256 allocation = vesting.allocations(user1);
        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        vesting.release();

        assertEq(token.balanceOf(user1), balanceBefore + allocation);
        assertEq(vesting.released(user1), allocation);
    }

    function test_Release_NoDoubleRelease() public {
        _setupAllocations();
        vm.warp(vestingStartTime + VESTING_DURATION);

        vm.prank(user1);
        vesting.release();

        // Try to release again
        vm.expectRevert("No tokens to release");
        vm.prank(user1);
        vesting.release();
    }

    function test_Release_RevertWhen_AllocationsNotLocked() public {
        address[] memory users = new address[](1);
        uint256[] memory allocations = new uint256[](1);
        users[0] = user1;
        allocations[0] = 10000e18;

        vm.prank(updater);
        vesting.setUserAllocations(users, allocations);

        vm.warp(vestingStartTime);

        vm.expectRevert("Allocations are not locked");
        vm.prank(user1);
        vesting.release();
    }

    function test_Release_RevertWhen_Paused() public {
        _setupAllocations();
        vm.warp(vestingStartTime);

        vm.prank(pauser);
        vesting.pause();

        vm.expectRevert(); // EnforcedPause() in newer OpenZeppelin versions
        vm.prank(user1);
        vesting.release();
    }

    function test_Release_RevertWhen_NoAllocation() public {
        _setupAllocations();
        vm.warp(vestingStartTime);

        address userWithNoAllocation = makeAddr("noAllocation");

        vm.expectRevert("No tokens to release");
        vm.prank(userWithNoAllocation);
        vesting.release();
    }

    // ============ releasable Tests ============

    function test_Releasable_Accuracy() public {
        _setupAllocations();
        vm.warp(vestingStartTime + (VESTING_DURATION / 3));

        uint256 releasable = vesting.releasable(user1);
        uint256 vestingSchedule = vesting.vestingSchedule(user1);
        uint256 released = vesting.released(user1);

        assertEq(releasable, vestingSchedule - released);
    }

    function test_Releasable_AfterPartialRelease() public {
        _setupAllocations();
        vm.warp(vestingStartTime);

        // Release initial amount
        vm.prank(user1);
        vesting.release();

        // Move time forward
        vm.warp(vestingStartTime + (VESTING_DURATION / 2));

        uint256 releasable = vesting.releasable(user1);
        uint256 vestingSchedule = vesting.vestingSchedule(user1);
        uint256 released = vesting.released(user1);

        assertEq(releasable, vestingSchedule - released);
        assertTrue(releasable > 0);
    }

    // ============ sweepTokens Tests ============

    function test_SweepTokens_Success() public {
        vm.prank(pauser);
        vesting.pause();

        uint256 sweepAmount = 1000e18;
        uint256 balanceBefore = token.balanceOf(user1);
        uint256 contractBalanceBefore = token.balanceOf(address(vesting));

        vm.expectEmit(true, false, false, true);
        emit TokensSwept(user1, sweepAmount);

        vesting.sweepTokens(user1, sweepAmount);

        assertEq(token.balanceOf(user1), balanceBefore + sweepAmount);
        assertEq(token.balanceOf(address(vesting)), contractBalanceBefore - sweepAmount);
    }

    function test_SweepTokens_RevertWhen_NotOwner() public {
        vm.prank(pauser);
        vesting.pause();

        vm.expectRevert();
        vm.prank(user1);
        vesting.sweepTokens(user2, 1000e18);
    }

    function test_SweepTokens_RevertWhen_NotPaused() public {
        vm.expectRevert(); // ExpectedPause() in newer OpenZeppelin versions
        vesting.sweepTokens(user1, 1000e18);
    }

    function test_SweepTokens_RevertWhen_InvalidRecipient() public {
        vm.prank(pauser);
        vesting.pause();

        vm.expectRevert("invalid recipient");
        vesting.sweepTokens(address(0), 1000e18);
    }

    function test_SweepTokens_RevertWhen_ZeroAmount() public {
        vm.prank(pauser);
        vesting.pause();

        vm.expectRevert("amount must be greater than 0");
        vesting.sweepTokens(user1, 0);
    }

    function test_SweepTokens_RevertWhen_InsufficientBalance() public {
        vm.prank(pauser);
        vesting.pause();

        uint256 contractBalance = token.balanceOf(address(vesting));

        vm.expectRevert("insufficient balance");
        vesting.sweepTokens(user1, contractBalance + 1);
    }

    // ============ Integration Tests ============

    // ============ Fuzz Tests ============

    function testFuzz_VestingSchedule_LinearProgression(uint256 timestamp) public view {
        uint256 allocation = 10000e18;

        // Bound timestamp to valid range
        timestamp = bound(timestamp, vestingStartTime, vestingStartTime + VESTING_DURATION);

        uint256 vested = vesting.vestingSchedule(allocation, timestamp);
        uint256 initialVested = (allocation * INIT_VESTED_BPS) / vesting.BPS_DENOMINATOR();

        // Should always be at least initial vested amount
        assertGe(vested, initialVested);
        // Should never exceed total allocation
        assertLe(vested, allocation);
    }

    function testFuzz_Release_Consistency(uint256 timeElapsed) public {
        _setupAllocations();

        // Bound time to reasonable range
        timeElapsed = bound(timeElapsed, 0, VESTING_DURATION);
        uint256 releaseTime = vestingStartTime + timeElapsed;
        vm.warp(releaseTime);

        uint256 releasableBefore = vesting.releasable(user1);
        if (releasableBefore > 0) {
            vm.prank(user1);
            vesting.release();

            assertEq(vesting.releasable(user1), 0);
            assertEq(vesting.released(user1), releasableBefore);
        }
    }

    // ============ Gas Tests ============

    function test_Gas_Release() public {
        _setupAllocations();
        vm.warp(vestingStartTime);

        uint256 gasBefore = gasleft();
        vm.prank(user1);
        vesting.release();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for release:", gasUsed);
        assertTrue(gasUsed < 200000); // Should be reasonably efficient
    }

    function test_Gas_VestingScheduleCalculation() public view {
        uint256 allocation = 10000e18;
        uint256 timestamp = vestingStartTime + (VESTING_DURATION / 2);

        uint256 gasBefore = gasleft();
        vesting.vestingSchedule(allocation, timestamp);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for vesting schedule calculation:", gasUsed);
        assertTrue(gasUsed < 50000); // Should be very efficient
    }
}
