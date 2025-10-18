// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployTokenVesting (JSON-config)
 * @notice Deploys a TokenVesting contract using parameters from a JSON config file.
 *
 * @dev Usage:
 *   forge script script/DeployTokenVesting.s.sol:DeployTokenVesting --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify -vv
 *
 * Env vars:
 *   - RPC_URL             RPC endpoint
 *   - PRIVATE_KEY         Deployer private key (0x-prefixed hex)
 *   - ETHERSCAN_API_KEY   Optional; required if using --verify
 *   - VESTING_CONFIG      Path to JSON config (e.g., script/example_config.json)
 *
 * JSON fields (see script/example_config.json):
 *   {
 *     "vestingToken": "0x...",              // optional; 0x0 allowed, can set later via setToken
 *     "vestingUpdater": "0x...",            // optional; defaults to deployer if omitted
 *     "vestingPauser": "0x...",             // optional; defaults to deployer if omitted
 *     "initBps": 1000,                       // optional
 *     "startTime": 1730000000,               // optional; if set, duration must also be set
 *     "duration": 31536000,                  // optional; if set, startTime must also be set
 *     "granularitySeconds": 86400            // optional; defaults to 86400 when setting params
 *   }
 *
 * Notes:
 * - Vesting parameters are only applied if both startTime and duration are present and > 0.
 * - granularitySeconds defaults to 86400 (daily) when applying parameters and omitted in JSON.
 * - updater/pauser default to the deployer if not provided.
 */
contract DeployTokenVesting is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory configPath = vm.envString("VESTING_CONFIG");
        string memory json = vm.readFile(configPath);

        // Addresses (tolerate empty-string values by falling back to defaults)
        address tokenAddr = address(0);
        if (json.keyExists("$.vestingToken")) {
            // Accept 0x0 or a real address; if invalid, this will revert (intentional)
            tokenAddr = json.readAddressOr("$.vestingToken", address(0));
        }

        address updater = deployer;
        if (json.keyExists("$.vestingUpdater")) {
            string memory updaterStr = json.readStringOr("$.vestingUpdater", "");
            if (bytes(updaterStr).length != 0) {
                updater = json.readAddress("$.vestingUpdater");
            }
        }

        address pauser = deployer;
        if (json.keyExists("$.vestingPauser")) {
            string memory pauserStr = json.readStringOr("$.vestingPauser", "");
            if (bytes(pauserStr).length != 0) {
                pauser = json.readAddress("$.vestingPauser");
            }
        }

        vm.startBroadcast(pk);

        TokenVesting vesting = new TokenVesting(IERC20(tokenAddr), updater, pauser);

        // Optionally set vesting parameters if provided
        bool hasStart = json.keyExists("$.startTime");
        bool hasDur = json.keyExists("$.duration");
        if (hasStart && hasDur) {
            uint256 initBps = json.readUintOr("$.initBps", 0);
            uint256 startTime = json.readUint("$.startTime");
            uint256 duration = json.readUint("$.duration");
            uint256 granularity = json.readUintOr("$.granularitySeconds", 86400);
            if (startTime > 0 && duration > 0) {
                vesting.setVestingParameters(initBps, startTime, duration, granularity);
            }
        }

        vm.stopBroadcast();

        console2.log("TokenVesting deployed:", address(vesting));
        console2.log("token:", tokenAddr);
        console2.log("updater:", updater);
        console2.log("pauser:", pauser);
    }
}
