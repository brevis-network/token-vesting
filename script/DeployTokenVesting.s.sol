// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * forge script script/DeployTokenVesting.s.sol:DeployTokenVesting --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify -vv
 *
 * Required environment variables:
 * - PRIVATE_KEY: Private key of the deployer
 * - ETHERSCAN_API_KEY: API key for contract verification
 *
 * Env example file: script/.env.example
 * To load vars into your shell before running:
 *   set -a; source script/.env; set +a
 *
 * Optional env vars:
 * - VESTING_TOKEN        Address of the ERC20 token (defaults to address(0))
 * - VESTING_UPDATER      Address granted UPDATER_ROLE (defaults to deployer)
 * - VESTING_PAUSER       Address granted PAUSER_ROLE (defaults to deployer)
 * - INIT_BPS             Initial vested basis points (e.g., 1000 = 10%). 0 is allowed.
 * - START_TIME           Vesting start timestamp (seconds, must be > 0 if provided)
 * - DURATION             Vesting duration in seconds (must be > 0 if provided)
 * - GRANULARITY_SECONDS  Step size in seconds for linear accrual (e.g., 86400 for daily). If not set
 *                        but parameters are provided, defaults to 86400.
 *
 * Parameter auto-set behavior:
 *   If any of START_TIME or DURATION (or INIT_BPS) is non-zero, the script will attempt to
 *   call setVestingParameters(initBps, startTime, duration, granularitySeconds). START_TIME and DURATION must
 *   both be non-zero in that case. INIT_BPS may be zero. GRANULARITY_SECONDS will default to 86400
 *   if not explicitly provided.
 */
contract DeployTokenVesting is Script {
    function run() external {
        vm.startBroadcast();

        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));

        address tokenAddr = vm.envOr("VESTING_TOKEN", address(0));
        address updater = vm.envOr("VESTING_UPDATER", sender);
        address pauser = vm.envOr("VESTING_PAUSER", sender);

        TokenVesting vesting = new TokenVesting(IERC20(tokenAddr), updater, pauser);
        console2.log("TokenVesting deployed:", address(vesting));

        // Read optional parameters with defaults (0 means "not provided" for start/duration)
        uint256 initBps = vm.envOr("INIT_BPS", uint256(0));
        uint256 startTime = vm.envOr("START_TIME", uint256(0));
        uint256 duration = vm.envOr("DURATION", uint256(0));
        // Only applied if we set parameters; default to daily (86400) when applying
        uint256 granularitySeconds = vm.envOr("GRANULARITY_SECONDS", uint256(0));

        bool anyProvided = (startTime != 0) || (duration != 0) || (initBps != 0);
        if (anyProvided) {
            require(startTime != 0 && duration != 0, "MISSING_START_OR_DURATION");
            if (granularitySeconds == 0) {
                granularitySeconds = 86400; // default to daily steps
            }
            vesting.setVestingParameters(initBps, startTime, duration, granularitySeconds);
            console2.log("Vesting parameters set");
            console2.log("initBps,start,duration:", initBps, startTime, duration);
            console2.log("granularity:", granularitySeconds);
        }

        vm.stopBroadcast();
    }
}
