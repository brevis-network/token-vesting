// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../test/TestToken.sol";

/**
 * @title DeployTestToken
 * @dev Deployment script for TestToken contract
 *
 * Usage:
 * forge script script/DeployTestToken.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --verify -vv
 *
 * Environment variables required:
 * - RPC_URL: RPC URL of the target network
 * - PRIVATE_KEY: Private key of the deployer (will become owner and receive initial tokens)
 * - ETHERSCAN_API_KEY: API key for contract verification on Etherscan
 */
contract DeployTestToken is Script {
    function run() external {
        // Get deployer address
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying TestToken...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy TestToken
        TestToken testToken = new TestToken();

        vm.stopBroadcast();

        console.log("TestToken deployed at:", address(testToken));
        console.log("Token name:", testToken.name());
        console.log("Token symbol:", testToken.symbol());
        console.log("Initial supply:", testToken.totalSupply());
        console.log("Deployer balance:", testToken.balanceOf(deployer));
        console.log("Owner:", testToken.owner());
    }
}
