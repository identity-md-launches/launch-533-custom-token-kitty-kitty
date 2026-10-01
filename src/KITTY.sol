// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IKittyLaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}

/// @title KITTY
/// @notice Fixed-supply token with a 2% dead-address fee on ordinary transfers.
/// @dev The immutable launch integration exempts factory/distributor operations and PoolManager
/// settlement. These exceptions are required for full-value launch distributions and v4 swaps.
contract KITTY is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant FEE_BPS = 200;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;

    error InvalidFactory();
    error InvalidPoolManager();

    /// @param factory_ The deploying ProjectFactory; receives the entire supply.
    /// @param poolManager_ The launch's Uniswap v4 PoolManager.
    /// @param launchNumber_ The launch identifier used to resolve its distributor dynamically.
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("KITTY", "KITTY") {
        if (factory_ == address(0) || factory_ != msg.sender || factory_ == DEAD) revert InvalidFactory();
        if (poolManager_ == address(0) || poolManager_ == DEAD || poolManager_ == factory_) {
            revert InvalidPoolManager();
        }
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @dev ERC20 transfer and transferFrom share this path; allowances always cover the gross amount.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || _isLaunchTransfer(to)) {
            super._update(from, to, value);
            return;
        }

        // Check the gross balance before splitting, including when sender == recipient == DEAD.
        uint256 balance = balanceOf(from);
        if (balance < value) revert ERC20InsufficientBalance(from, balance, value);

        // Exactly floor(value * 2 / 100), without an intermediate multiplication overflow.
        uint256 fee = value / 50;
        if (fee != 0) super._update(from, DEAD, fee);
        super._update(from, to, value - fee);
    }

    function _isLaunchTransfer(address to) private view returns (bool) {
        address caller = _msgSender();
        if (caller == factory || caller == poolManager || to == poolManager) return true;

        // The distributor depends on this token's CREATE2 address, so cannot be a constructor argument.
        // A failed lookup must not freeze ordinary holders; it simply grants no distributor exemption.
        bytes memory query = abi.encodeCall(IKittyLaunchFactory.distributorOf, (launchNumber));
        address target = factory;
        bool success;
        uint256 response;
        assembly ("memory-safe") {
            // Bound both execution gas and copied return data; only one ABI word is needed.
            success := staticcall(30000, target, add(query, 0x20), mload(query), 0x00, 0x20)
            success := and(success, eq(returndatasize(), 0x20))
            response := mload(0x00)
        }
        // Compare the full word so malformed address padding cannot grant an exemption.
        return success && caller != address(0) && response == uint256(uint160(caller));
    }
}
