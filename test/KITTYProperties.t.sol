// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KITTY} from "src/KITTY.sol";
import {KittyFactoryMock} from "./helpers/KittyFactoryMock.sol";

/// @notice Complementary properties for aliases, rounding, and rejected exempt transfers.
/// forge-config: default.fuzz.runs = 1000
contract KITTYPropertiesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    address private constant MANAGER = address(0xA000);
    address private constant DISTRIBUTOR = address(0xD157);

    KittyFactoryMock private factory;
    KITTY private token;

    function setUp() public {
        factory = new KittyFactoryMock();
        token = factory.deploy(MANAGER, 42);
        factory.setDistributor(42, DISTRIBUTOR);
    }

    function test_fullSupplyRoundTripChargesBothLegsWithoutBurningSupply() public {
        assertTrue(factory.move(token, ALICE, SUPPLY));
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, SUPPLY));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 980_000_000 ether);
        assertEq(token.balanceOf(DEAD), 20_000_000 ether);

        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, 980_000_000 ether));
        assertEq(token.balanceOf(ALICE), 960_400_000 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 39_600_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_directAndDelegatedTransfersAgreeForRecipientAliases(
        uint256 holding,
        uint256 amount,
        uint256 recipientSeed,
        bool callerIsOwner,
        bool unlimited
    ) public {
        holding = bound(holding, 0, SUPPLY);
        amount = bound(amount, 0, holding);
        address[4] memory recipients = [ALICE, SPENDER, DEAD, address(token)];
        address recipient = recipients[recipientSeed % recipients.length];
        address spender = callerIsOwner ? ALICE : SPENDER;
        uint256 allowance = unlimited ? type(uint256).max : amount;

        assertTrue(factory.move(token, ALICE, holding));
        vm.prank(ALICE);
        assertTrue(token.approve(spender, allowance));
        uint256 snapshot = vm.snapshotState();

        vm.prank(ALICE);
        assertTrue(token.transfer(recipient, amount));
        bytes32 directBalances = _balanceDigest();
        assertEq(token.allowance(ALICE, spender), allowance, "direct transfer spent approval");
        if (recipient == DEAD) {
            assertEq(token.balanceOf(DEAD), amount);
            assertEq(token.balanceOf(ALICE), holding - amount);
        } else {
            uint256 fee = token.balanceOf(DEAD);
            // Bound the observed fee by the exact rational percentage and one minor unit.
            assertLe(fee * 100, amount * 2);
            assertLt(amount * 2, (fee + 1) * 100);
            assertEq(token.balanceOf(ALICE), recipient == ALICE ? holding - fee : holding - amount);
            if (recipient != ALICE) assertEq(token.balanceOf(recipient), amount - fee);
        }
        assertEq(token.totalSupply(), SUPPLY);

        assertTrue(vm.revertToState(snapshot));
        vm.prank(spender);
        assertTrue(token.transferFrom(ALICE, recipient, amount));
        assertEq(_balanceDigest(), directBalances, "transferFrom differs from transfer");
        assertEq(token.allowance(ALICE, spender), unlimited ? type(uint256).max : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitTransfersLoseAtMostOneFeeWeiToRounding(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        uint256 total = first + second;
        assertTrue(factory.move(token, ALICE, total));
        uint256 snapshot = vm.snapshotState();

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, total));
        uint256 combinedFee = token.balanceOf(DEAD);
        assertEq(token.balanceOf(BOB), total - combinedFee);

        assertTrue(vm.revertToState(snapshot));
        vm.startPrank(ALICE);
        assertTrue(token.transfer(BOB, first));
        assertTrue(token.transfer(BOB, second));
        vm.stopPrank();
        uint256 splitFee = token.balanceOf(DEAD);
        // floor(x) + floor(y) differs from floor(x + y) by at most one.
        assertLe(splitFee, combinedFee);
        assertLe(combinedFee, splitFee + 1);
        assertEq(token.balanceOf(BOB), total - splitFee);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(factory)), SUPPLY - total);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_exemptionNeverAuthorizesSpendingBeyondAllowance(
        uint256 amount,
        uint256 callerSeed,
        uint256 recipientSeed
    ) public {
        amount = bound(amount, 1, SUPPLY);
        address caller = _caller(callerSeed);
        address recipient = _recipient(recipientSeed);
        assertTrue(factory.move(token, ALICE, amount));
        vm.prank(ALICE);
        assertTrue(token.approve(caller, amount - 1));
        bytes32 beforeBalances = _balanceDigest();

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, amount - 1, amount)
        );
        vm.prank(caller);
        token.transferFrom(ALICE, recipient, amount);
        assertEq(token.allowance(ALICE, caller), amount - 1);
        assertEq(_balanceDigest(), beforeBalances, "rejected spend moved value");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_maximumDelegatedAmountCannotOverflowOrOverdrawEvenIfExempt(
        uint256 holding,
        uint256 callerSeed,
        uint256 recipientSeed
    ) public {
        holding = bound(holding, 0, SUPPLY);
        address caller = _caller(callerSeed);
        address recipient = _recipient(recipientSeed);
        assertTrue(factory.move(token, ALICE, holding));
        vm.prank(ALICE);
        assertTrue(token.approve(caller, type(uint256).max));
        bytes32 beforeBalances = _balanceDigest();

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, holding, type(uint256).max)
        );
        vm.prank(caller);
        token.transferFrom(ALICE, recipient, type(uint256).max);
        assertEq(token.allowance(ALICE, caller), type(uint256).max);
        assertEq(_balanceDigest(), beforeBalances, "rejected overdraw moved value");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _caller(uint256 seed) private view returns (address) {
        address[4] memory callers = [address(factory), MANAGER, DISTRIBUTOR, SPENDER];
        return callers[seed % callers.length];
    }

    function _recipient(uint256 seed) private pure returns (address) {
        address[4] memory recipients = [ALICE, BOB, DEAD, MANAGER];
        return recipients[seed % recipients.length];
    }

    function _balanceDigest() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(SPENDER),
                token.balanceOf(DEAD),
                token.balanceOf(MANAGER),
                token.balanceOf(DISTRIBUTOR),
                token.balanceOf(address(factory)),
                token.balanceOf(address(token))
            )
        );
    }
}
