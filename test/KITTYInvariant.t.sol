// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {KITTY} from "../src/KITTY.sol";

/// @dev Exercises arbitrary sequences of ordinary direct and delegated transfers, including self
/// transfers and transfers to DEAD. Only funded actors send; DEAD is never impersonated here.
contract KittyTransferHandler is Test {
    KITTY public immutable token;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256 public expectedDeadBalance;
    uint256 public transfers;

    constructor(KITTY token_) {
        token = token_;
    }

    function send(uint256 senderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        (address from, address to, uint256 amount) = _transferArgs(senderSeed, recipientSeed, amountSeed);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _record(to, amount);
    }

    function sendWithAllowance(uint256 senderSeed, uint256 recipientSeed, uint256 amountSeed, bool unlimited) external {
        (address from, address to, uint256 amount) = _transferArgs(senderSeed, recipientSeed, amountSeed);
        vm.prank(from);
        assertTrue(token.approve(address(this), unlimited ? type(uint256).max : amount));
        assertTrue(token.transferFrom(from, to, amount));
        assertEq(token.allowance(from, address(this)), unlimited ? type(uint256).max : 0);
        _record(to, amount);
    }

    function _transferArgs(uint256 senderSeed, uint256 recipientSeed, uint256 amountSeed)
        private
        view
        returns (address from, address to, uint256 amount)
    {
        from = actors[senderSeed % actors.length];
        uint256 recipient = recipientSeed % (actors.length + 1);
        to = recipient == actors.length ? token.DEAD() : actors[recipient];
        amount = amountSeed % (token.balanceOf(from) + 1);
    }

    function _record(address to, uint256 amount) private {
        expectedDeadBalance += to == token.DEAD() ? amount : amount / 50;
        transfers++;
    }
}

contract KITTYInvariantTest is StdInvariant, Test {
    KITTY private token;
    KittyTransferHandler private handler;
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new KITTY(address(this), address(0xB00), 7);
        handler = new KittyTransferHandler(token);
        for (uint256 i; i < 4; ++i) {
            assertTrue(token.transfer(handler.actors(i), SUPPLY / 4));
        }

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = KittyTransferHandler.send.selector;
        selectors[1] = KittyTransferHandler.sendWithAllowance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function distributorOf(uint64) external pure returns (address) {
        return address(0);
    }

    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_allUnitsAreAccountedFor() public view {
        uint256 held = token.balanceOf(token.DEAD());
        for (uint256 i; i < 4; ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(held, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_deadBalanceMatchesFeesAndDirectDeposits() public view {
        assertEq(token.balanceOf(token.DEAD()), handler.expectedDeadBalance());
    }
}
