# Token Vesting Contracts

Foundry-based Solidity contracts for ERC20 token allocation and time-based vesting with an initial percentage unlock and linear release.

## Repository Layout
```
src/        Core contracts (TokenAllocation, TokenVesting)
script/     Deployment scripts and `.env.example`
test/       Foundry tests
lib/        Submodules (forge-std, openzeppelin, openzeppelin-v4, security)
```

## Vesting Model
Allocation `A` with params:
`I = initVestedBps (<= 10000)`, `T0 = startTime`, `D = duration`, current time `t`.

Vested amount `V(t)`:
- `0` for `t < T0`
- `A` for `t >= T0 + D`
- Otherwise `V(t) = A*I/10000 + (A - A*I/10000) * (t - T0) / D`

Releasable = `V(t) - released[user]`.

## Operational Flow
1. Deploy contract with token, updater, pauser (optional zero addresses allowed, then set later by owner).
2. (Owner) `setVestingParameters(initBps, startTime, duration)` – must be before locking.
3. (Updater) `setUserAllocations([...])` – batch set or update allocations while not locked.
4. (Owner or Updater) `lockAllocations()` – freezes allocations and parameters.
5. Fund the contract. Use `fundingGap()` to check surplus/deficit vs aggregate releasable.
6. Users call `release()` (or anyone calls `release(user)`) after `startTime` as vesting accrues.
