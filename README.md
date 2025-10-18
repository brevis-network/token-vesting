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

## Operational Flow
1. Deploy contract with token, updater, pauser (optional zero addresses allowed, then set later by owner).
2. (Owner) `setVestingParameters(initBps, startTime, duration, granularitySeconds)`.
3. (Updater) `setAllocations([...])` – batch set or update allocations while not locked.
4. (Owner) If updater/pauser are less trusted: review allocations and revoke `UPDATER_ROLE` from non-owners. `pause()` can serve as a temporary guard.
5. (Owner) `lockAllocations()` – freezes allocations and parameters.
6. Fund the contract. Use `fundingGap()` to check surplus/deficit vs aggregate releasable.
7. Beneficiaries call `release()` (or updater calls `release(beneficiary)`) after `startTime` as vesting accrues.
8. View helpers: `beneficiaryVestingInfo(beneficiary)`, `releasable(beneficiary)`, `fundingGap()`.

## Security Considerations

### Trust model and roles
- `owner` is a super-admin and must be tightly secured. We recommend using the built-in OwnerCouncil (see `src/OwnerCouncil.sol`) for on-chain governance, or a multisig.
- `UPDATER_ROLE` updates allocations until locked; `PAUSER_ROLE` can pause operations (global and per-beneficiary in vesting). Key management follows standard operational practice. See the Operational Flow for the recommended sequence (review, revoke `UPDATER_ROLE` if needed, then lock).

### Allocation locking and mutability
- Allocations and vesting parameters are immutable after `allocationLocked` is set (cannot be unset).
- Post-lock recovery: `pause()` + `sweepTokens` to recover excess, then remediate off-chain (redeploy/migrate or compensate). No post-lock edits are supported.
- Operationally, finalize parameters and allocations, then lock before funding/enabling releases to avoid misconfiguration or last-minute changes.