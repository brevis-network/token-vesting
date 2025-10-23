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
Each beneficiary follows the same schedule: at the vesting start time (`T0`), a fixed initial percentage (`P`) of their allocation (`A`) unlocks immediately, and the remainder vests in linear steps over the configured duration (`D`). The step size is controlled by vesting granularity (`G`) in seconds (e.g., `86400` for daily steps).

Vested amount `V(t)` at current time `t`:
- `V(t) = 0` for `t < T0`
- `V(t) = A` for `t >= T0 + D`
- Otherwise `V(t) = A * P + A * (1 - P) * stepsElapsed / stepsTotal`, where `stepsTotal = ceil(D / G)` and `stepsElapsed = floor((t - T0) / G)`.

`releasable = V(t) - released[beneficiary]`.

## Operation Flow
1. Deploy contract with token, updater, and pauser.
2. (Owner) `setVestingParameters(initBps, startTime, duration, granularitySeconds)`.
3. (Updater/Pauser)
    1) `setAllocations([...])` – batch-set or update allocations while not locked.
    2) `pause()` during review to prevent unintended changes.
    3) Renounce `UPDATER_ROLE` once allocations are confirmed.
4. (Team) Carefully review allocations.
5. (Owner) `lockAllocations()` – freezes allocations and parameters.
6. Beneficiaries call `release()` (or updater calls `release(beneficiary)`) after `startTime` as vesting accrues.

## Security Considerations

### Trust model and roles
- `owner` is a super-admin and must be tightly secured. We recommend using the built-in OwnerCouncil (see `src/OwnerCouncil.sol`) for on-chain governance, or a multisig.
- `UPDATER_ROLE` updates allocations until locked; `PAUSER_ROLE` can pause operations (global and per-beneficiary in vesting). Key management follows standard operational practice. See the Operation Flow for the recommended sequence (review, revoke `UPDATER_ROLE` if needed, then lock).

### Allocation locking and mutability
- Allocations and vesting parameters are immutable after `allocationLocked` is set (cannot be unset).
- Post-lock recovery: `pause()` + `sweepTokens` to recover excess, then remediate off-chain (redeploy/migrate or compensate). No post-lock edits are supported.
- Operationally, finalize parameters and allocations, then lock before funding/enabling releases to avoid misconfiguration or last-minute changes.