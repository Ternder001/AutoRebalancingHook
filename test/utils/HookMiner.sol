// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "v4-core/libraries/Hooks.sol";

library HookMiner {
    // Find a salt that will produce a hook address with the desired flags
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) external view returns (address hookAddress, bytes32 salt) {
        // Concatenate the creation code and constructor arguments
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        // Start with a random salt
        salt = keccak256(abi.encodePacked(block.timestamp, deployer));

        // Keep trying different salts until we find one that produces an address with the desired flags
        while (true) {
            hookAddress = computeAddress(deployer, bytecode, salt);

            // Check if the hook address has the desired flags
            if (hasPermission(uint160(hookAddress), flags)) {
                break;
            }

            // Try a different salt
            salt = keccak256(abi.encodePacked(salt));
        }
    }

    // Compute the address of a contract deployed using CREATE2
    function computeAddress(
        address deployer,
        bytes memory bytecode,
        bytes32 salt
    ) internal pure returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                deployer,
                                salt,
                                keccak256(bytecode)
                            )
                        )
                    )
                )
            );
    }

    // Check if an address has the desired hook permissions
    function hasPermission(
        uint160 hookAddress,
        uint160 flags
    ) internal pure returns (bool) {
        // The hook address must have the correct flags in the lower 20 bits
        return (hookAddress & Hooks.ALL_HOOK_MASK) == flags;
    }
}
