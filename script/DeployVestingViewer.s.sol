// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import {VestingViewer} from "../src/VestingViewer.sol";

/**
 * VestingViewer - JSON-config deployment
 *
 * Usage:
 *   forge script script/DeployVestingViewer.s.sol:DeployVestingViewer --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify -vv
 *
 * Env vars:
 *   RPC_URL             RPC endpoint
 *   PRIVATE_KEY         Deployer private key (0x-prefixed hex)
 *   ETHERSCAN_API_KEY   Optional; required if using --verify
 *   VESTING_CONFIG      Path to JSON config (e.g., script/example_config.json)
 *
 * JSON fields (see script/example_config.json):
 *   {
 *     "viewer": {
 *       "vesting": "0x..."   // address of the deployed TokenVesting to view
 *     }
 *   }
 */
contract DeployVestingViewer is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory configPath = vm.envString("VESTING_CONFIG");
        string memory json = vm.readFile(configPath);

        address vesting = json.readAddress("$.viewer.vesting");
        require(vesting != address(0), "viewer.vesting is required");

        vm.startBroadcast(pk);
        VestingViewer viewer = new VestingViewer(vesting);
        vm.stopBroadcast();

        console2.log("VestingViewer deployed:", address(viewer));
        console2.log("target vesting:", vesting);
    }
}
