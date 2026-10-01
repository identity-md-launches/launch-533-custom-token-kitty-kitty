// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KITTY} from "../../src/KITTY.sol";

/// @dev Test-only factory with deliberately hostile distributor lookup responses.
contract KittyFactoryMock {
    enum LookupMode {
        Normal,
        Revert,
        Empty,
        Short,
        Oversized,
        DirtyAddress,
        ExhaustGas
    }

    mapping(uint64 => address) private distributors;
    LookupMode public mode;

    function deploy(address poolManager, uint64 launchNumber) external returns (KITTY) {
        return new KITTY(address(this), poolManager, launchNumber);
    }

    function move(KITTY token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function setDistributor(uint64 launchNumber, address distributor) external {
        distributors[launchNumber] = distributor;
    }

    function setMode(LookupMode mode_) external {
        mode = mode_;
    }

    function distributorOf(uint64 launchNumber) external view returns (address) {
        address distributor = distributors[launchNumber];
        LookupMode mode_ = mode;
        if (mode_ == LookupMode.Revert) revert("lookup unavailable");
        if (mode_ == LookupMode.Empty) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode_ == LookupMode.Short) {
            assembly ("memory-safe") {
                mstore(0, distributor)
                return(0, 31)
            }
        }
        if (mode_ == LookupMode.Oversized) {
            assembly ("memory-safe") {
                mstore(0, distributor)
                mstore(0x20, 0)
                return(0, 64)
            }
        }
        if (mode_ == LookupMode.DirtyAddress) {
            assembly ("memory-safe") {
                mstore(0, or(distributor, shl(160, 1)))
                return(0, 32)
            }
        }
        if (mode_ == LookupMode.ExhaustGas) {
            assembly ("memory-safe") {
                for {} 1 {} {}
            }
        }
        return distributor;
    }
}
