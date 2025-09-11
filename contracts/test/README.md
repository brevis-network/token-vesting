# TokenVesting Test Suite

Test suite for the TokenVesting smart contract.

## Contract Architecture

- `TokenAllocation`: Abstract base contract for user allocation management
- `TokenVesting`: Concrete implementation with time-based token release

## Test Files

- `TokenAllocationTest.t.sol`: 15 tests - Allocation logic and access control
- `TokenVestingTest.t.sol`: 40 tests - Vesting mechanics and token release
- `IntegrationTest.t.sol`: 6 tests - End-to-end workflow validation

Total: 61 tests

## Running Tests

```bash
# Run all tests
forge test

# Verbose output
forge test -vv

# Specific contract
forge test --match-contract TokenVesting

# Gas analysis
forge test --gas-report

# Fuzz tests with more runs
forge test --match-test "testFuzz_" --fuzz-runs 1000
```

## Key Test Coverage

### Allocation Management
- User allocation setting and updates
- Access control (updater/owner roles)
- Allocation locking mechanism
- Edge cases (zero amounts, max values)

### Vesting Mechanics  
- Linear vesting schedule calculations
- Initial vesting percentage (configurable)
- Token release at different time points
- Multiple release transactions

### Integration Scenarios
- Complete allocation-to-release workflows
- Large scale operations (1000+ users)
- Emergency pause/resume functionality
- Token sweeping for excess funds

### Security Testing
- Role-based access control
- Input validation and error handling
- Pausing mechanism

## Performance Benchmarks

Gas costs from actual test measurements:

### `setUserAllocations` Gas Cost Analysis
- **Small batch (4 users)**: 150,076 gas = ~37,519 gas per user (high overhead)
- **Large batch (1000 users)**: ~26,392,084 gas = ~26,392 gas per user (amortized overhead)
- **Fixed overhead**: ~25K gas baseline + ~22K gas per user

### Other Operations
- `release`: ~89K gas per release operation
- `vestingSchedule`: ~13K gas per calculation

### How to Measure

```bash
# See gas usage for 1000 users (shows total gas in test output)
forge test --match-test "test_LargeScaleAllocation" -v

# To test different batch sizes, modify the numUsers variable in test_LargeScaleAllocation
```

## Critical Validations

- Mathematical precision across all vesting calculations
- Total allocation consistency 
- Proper event emissions
- Access control boundaries
- Emergency function restrictions

