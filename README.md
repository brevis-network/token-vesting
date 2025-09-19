# Token Vesting Contracts

Foundry-based Solidity contracts for ERC20 token allocation and time-based vesting with an initial percentage unlock and linear release.

## Repository Layout
```
src/        Core contracts (TokenAllocation, TokenVesting)
lib/        Submodules (forge-std, openzeppelin, openzeppelin-v4, security)
test/       Foundry tests
script/     Deployment scripts and `.env.example`
```

## Vesting Model
Each beneficiary follows the same schedule: at the vesting start time (`T0`), a fixed initial percentage (`P`) of their allocation (`A`) unlocks immediately, and the remainder vests linearly over the configured duration (`D`). 

Vested amount `V(t)` at current time `t`:
- `V(t) = 0` for `t < T0`
- `V(t) = A` for `t >= T0 + D`
- Otherwise `V(t) = A * P + A * (1 - P) * (t - T0) / D`

`releasable = V(t) - released[beneficiary]`.

## Operational Flow
1. Deploy contract with token, updater, pauser (optional zero addresses allowed, then set later by owner).
2. (Owner) `setVestingParameters(initBps, startTime, duration)` – must be before locking.
3. (Updater) `setAllocations([...])` – batch set or update allocations while not locked.
4. (Owner or Updater) `lockAllocations()` – freezes allocations and parameters.
5. Fund the contract. Use `fundingGap()` to check surplus/deficit vs aggregate releasable.
6. Beneficiaries call `release()` (or updater calls `release(beneficiary)`) after `startTime` as vesting accrues.
7. View helpers: `beneficiaryVestingInfo(beneficiary)`, `releasable(beneficiary)`, `fundingGap()`.