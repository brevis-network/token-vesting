// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * forge script contracts/scripts/DeployTokenVesting.s.sol:DeployTokenVesting --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vv
 *
 * Env example file: contracts/scripts/.env.example
 * To load vars into your shell before running:
 *   set -a; source contracts/scripts/.env; set +a
 *
 * Env vars (optional):
 * - VESTING_TOKEN      Address of the ERC20 token (defaults to address(0))
 * - VESTING_UPDATER    Address granted UPDATER_ROLE (defaults to msg.sender)
 * - VESTING_PAUSER     Address granted PAUSER_ROLE (defaults to msg.sender)
 * - INIT_BPS           Initial vested basis points (e.g., 1000 = 10%)
 * - START_TIME         Vesting start timestamp (seconds)
 * - DURATION           Vesting duration in seconds
 * - SET_PARAMS         If "true", set vesting params after deploy
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

        bool setParams = vm.envOr("SET_PARAMS", false);
        if (setParams) {
            uint256 initBps = vm.envUint("INIT_BPS");
            uint256 startTime = vm.envUint("START_TIME");
            uint256 duration = vm.envUint("DURATION");
            vesting.setVestingParameters(initBps, startTime, duration);
            console2.log("Vesting parameters set:", initBps, startTime, duration);
        }

        vm.stopBroadcast();
    }
}
