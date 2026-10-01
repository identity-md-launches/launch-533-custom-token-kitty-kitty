// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KITTY} from "src/KITTY.sol";

/// @dev Allowances persist between independently chosen approval and spending actions. The model
/// starts from the declared allocation and never uses token balances or allowances as its oracle.
contract KittyAllowanceHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    KITTY public immutable token;
    address[4] public actors = [address(0x2101), address(0x2102), address(0x2103), address(0x2104)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(KITTY token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, uint8 mode) external {
        uint256 amount;
        if (mode % 4 == 1) amount = type(uint256).max;
        if (mode % 4 == 2) amount = bound(amountSeed, 0, SUPPLY);
        if (mode % 4 == 3) amount = amountSeed;
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function send(uint256 ownerSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address recipient = _recipient(recipientSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        vm.prank(owner);
        assertTrue(token.transfer(recipient, amount));
        _recordTransfer(owner, recipient, amount);
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = _recipient(recipientSeed);
        uint256 approved = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 amount = _amount(amountSeed, approved < available ? approved : available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, amount));
        if (approved != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _recordTransfer(owner, recipient, amount);
    }

    function rejectInsufficientAllowance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 recipientSeed,
        uint256 amountSeed
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = _recipient(recipientSeed);
        uint256 approved = bound(amountSeed, 0, SUPPLY);
        _approve(owner, spender, approved);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        vm.prank(spender);
        token.transferFrom(owner, recipient, approved + 1);
        // The invariant compares the unchanged model after every rejected operation.
    }

    function rejectInsufficientBalance(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 recipientSeed,
        uint256 amountSeed,
        bool delegated,
        bool unlimited
    ) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address recipient = _recipient(recipientSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        if (delegated) _approve(owner, spender, unlimited ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(delegated ? spender : owner);
        if (delegated) token.transferFrom(owner, recipient, amount);
        else token.transfer(recipient, amount);
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        // Use a finite approval so a missing rollback of _spendAllowance is observable.
        _approve(owner, spender, amount + 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function rejectZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
    }

    function assertModel() external view {
        uint256 accounted = token.balanceOf(DEAD);
        assertEq(accounted, expectedBalance[DEAD], "fees and explicit dead-address deposits");
        for (uint256 i; i < actors.length; ++i) {
            address owner = actors[i];
            uint256 balance = token.balanceOf(owner);
            assertEq(balance, expectedBalance[owner], "per-owner balance model");
            accounted += balance;
            for (uint256 j; j < actors.length; ++j) {
                address spender = actors[j];
                assertEq(token.allowance(owner, spender), expectedAllowance[owner][spender], "allowance model");
            }
            assertEq(token.allowance(owner, address(0)), 0, "zero spender cannot receive approval");
        }
        assertEq(accounted, SUPPLY, "all balances conserve initial supply");
        assertEq(token.totalSupply(), SUPPLY, "supply cannot change");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(token.factory()), 0);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _recordTransfer(address owner, address recipient, uint256 amount) private {
        // The specification's 2% of gross, rounded down. Bounded by the fixed supply.
        uint256 fee = amount * 2 / 100;
        expectedBalance[owner] -= amount;
        expectedBalance[recipient] += amount - fee;
        expectedBalance[DEAD] += fee;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = seed % (actors.length + 1);
        return index == actors.length ? DEAD : actors[index];
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        // Frequently hit zero, the full balance/allowance, and both sides of fee rounding.
        if (seed % 5 == 0) return maximum;
        if (seed % 5 == 1) return 0;
        if (seed % 5 == 2) return maximum < 49 ? maximum : 49;
        if (seed % 5 == 3) return maximum < 50 ? maximum : 50;
        return bound(seed, 0, maximum);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract KITTYAllowanceInvariantTest is StdInvariant, Test {
    KITTY private token;
    KittyAllowanceHandler private handler;

    function setUp() public {
        token = new KITTY(address(this), address(0x2200), 8);
        handler = new KittyAllowanceHandler(token);
        for (uint256 i; i < 4; ++i) {
            assertTrue(token.transfer(handler.actors(i), 250_000_000 ether));
            // Seed real spending opportunities before arbitrary approval/revocation sequences.
            handler.approve(i, (i + 1) % 4, 125_000_000 ether, 2);
        }

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = KittyAllowanceHandler.approve.selector;
        selectors[1] = KittyAllowanceHandler.send.selector;
        selectors[2] = KittyAllowanceHandler.spend.selector;
        selectors[3] = KittyAllowanceHandler.rejectInsufficientAllowance.selector;
        selectors[4] = KittyAllowanceHandler.rejectInsufficientBalance.selector;
        selectors[5] = KittyAllowanceHandler.rejectZeroRecipient.selector;
        selectors[6] = KittyAllowanceHandler.rejectZeroSpender.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function distributorOf(uint64) external pure returns (address) {
        return address(0);
    }

    function invariant_balancesAndEveryAllowanceMatchIndependentModel() public view {
        handler.assertModel();
    }

    function test_persistentAllowanceSequenceCoversRevocationReplacementAndRollback() public {
        address owner = handler.actors(0);
        address spender = handler.actors(1);

        handler.approve(0, 1, 100, 2);
        handler.spend(0, 1, 2, 3); // 50 gross, leaves 50 allowance.
        handler.send(0, 3, 2); // Direct transfers cannot consume any allowance.
        handler.assertModel();
        assertEq(token.allowance(owner, spender), 50);

        handler.rejectInsufficientBalance(0, 1, 2, 0, true, false);
        handler.rejectZeroRecipient(0, 1, 3);
        handler.rejectInsufficientAllowance(0, 1, 2, 0);
        handler.rejectZeroSpender(0, type(uint256).max);
        handler.assertModel();

        handler.approve(0, 1, 0, 1);
        handler.spend(0, 1, 0, 3); // Delegated self-transfer pays a fee; unlimited approval persists.
        handler.assertModel();
        assertEq(token.allowance(owner, spender), type(uint256).max);

        handler.approve(0, 1, 0, 0);
        handler.spend(0, 1, 2, 0); // Revoked approval permits only zero.
        handler.approve(0, 1, 100, 2);
        handler.spend(0, 1, 4, 0); // Spend the replacement allowance, depositing gross into DEAD.
        handler.assertModel();
        assertEq(token.allowance(owner, spender), 0);
    }
}
