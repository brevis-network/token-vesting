// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import {OwnerCouncil} from "../src/OwnerCouncil.sol";

/**
 * OwnerCouncil - JSON-config deployment
 *
 * Usage:
 *   forge script script/DeployOwnerCouncil.s.sol:DeployOwnerCouncil --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify -vv
 *
 * Env vars:
 *   RPC_URL             RPC endpoint
 *   PRIVATE_KEY         Deployer private key (0x-prefixed hex)
 *   ETHERSCAN_API_KEY   Optional; required if using --verify
 *   VESTING_CONFIG      Path to JSON config (e.g., script/example_config.json)
 *
 * JSON fields (see script/example_config.json):
 *   {
 *     "owner": {
 *       "voters": ["0x...","0x...", "0x..."],   // one or more addresses
 *       "requiredYesVotes": 2,                      // required yes votes to pass
 *       "activePeriod": 86400                       // seconds a proposal stays active
 *     }
 *   }
 *
 * Deploys an OwnerCouncil using voter addresses from a JSON config.
 *
 * Env:
 *  - PRIVATE_KEY: deployer key
 *  - VESTING_CONFIG: path to JSON config file
 */
contract DeployOwnerCouncil is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envString("VESTING_CONFIG");
        string memory json = vm.readFile(configPath);

        address[] memory voters = json.readAddressArray("$.owner.voters");
        uint256 requiredYesVotes = json.readUint("$.owner.requiredYesVotes");
        uint256 activePeriod = json.readUint("$.owner.activePeriod");

        vm.startBroadcast(pk);
        OwnerCouncil council = new OwnerCouncil(voters, requiredYesVotes, activePeriod);
        vm.stopBroadcast();

        console2.log("OwnerCouncil deployed:", address(council));
    }
}
