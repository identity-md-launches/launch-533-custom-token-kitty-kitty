// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KITTY} from "../src/KITTY.sol";
import {KittyFactoryMock} from "./helpers/KittyFactoryMock.sol";

contract KITTYTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address private constant MANAGER = address(0xA000);
    address private constant DISTRIBUTOR = address(0xD157);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    uint64 private constant LAUNCH = 42;

    KittyFactoryMock private factory;
    KITTY private token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        factory = new KittyFactoryMock();
        token = factory.deploy(MANAGER, LAUNCH);
    }

    function test_metadataAndEntireInitialSupplyBelongToDeployer() public view {
        assertEq(token.name(), "KITTY");
        assertEq(token.symbol(), "KITTY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.FEE_BPS(), 200);
        assertEq(token.DEAD(), DEAD);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), MANAGER);
        assertEq(token.launchNumber(), LAUNCH);
    }

    function test_constructorEmitsOneMintForEntireSupply() public {
        vm.recordLogs();
        KITTY deployed = factory.deploy(MANAGER, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(factory)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_transferDebitsGrossCreditsNetAndKeepsSupply() public {
        _fund(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEAD), 2 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferEmitsFeeThenNetEvents() public {
        _fund(ALICE, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, DEAD, 2 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 98 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
    }

    function test_roundingBoundariesAndZeroTransfer() public {
        uint256[5] memory amounts = [uint256(0), 1, 49, 50, 51];
        uint256[5] memory fees = [uint256(0), 0, 0, 1, 1];
        _fund(ALICE, 151);
        uint256 received;
        uint256 dead;
        uint256 sent;
        for (uint256 i; i < amounts.length; ++i) {
            vm.recordLogs();
            vm.prank(ALICE);
            assertTrue(token.transfer(BOB, amounts[i]));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, fees[i] == 0 ? 1 : 2);
            received += amounts[i] - fees[i];
            dead += fees[i];
            sent += amounts[i];
            assertEq(token.balanceOf(BOB), received);
            assertEq(token.balanceOf(DEAD), dead);
            assertEq(token.balanceOf(ALICE), 151 - sent);
            assertEq(logs[logs.length - 1].topics[1], bytes32(uint256(uint160(ALICE))));
            assertEq(logs[logs.length - 1].topics[2], bytes32(uint256(uint160(BOB))));
            assertEq(abi.decode(logs[logs.length - 1].data, (uint256)), amounts[i] - fees[i]);
        }
    }

    function test_zeroTransferFromNeedsNoAllowanceOrBalance() public {
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_transferFromSpendsGrossAllowance() public {
        _fund(ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 110 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100 ether));
        assertEq(token.allowance(ALICE, SPENDER), 10 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEAD), 2 ether);
    }

    function test_approveReplaceAndRevokeEmitEvents() public {
        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, SPENDER, 100);
        assertTrue(token.approve(SPENDER, 100));
        assertEq(token.allowance(ALICE, SPENDER), 100);
        assertTrue(token.approve(SPENDER, 5));
        assertEq(token.allowance(ALICE, SPENDER), 5);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, SPENDER, 0);
        assertTrue(token.approve(SPENDER, 0));
        vm.stopPrank();
        assertEq(token.allowance(ALICE, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        assertEq(token.balanceOf(BOB), 98);
        assertEq(token.balanceOf(DEAD), 2);
    }

    function test_selfTransferPaysOnlyFeeButRequiresGrossBalance() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 98);
        assertEq(token.balanceOf(DEAD), 2);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 98, 99));
        vm.prank(ALICE);
        token.transfer(ALICE, 99);
        assertEq(token.balanceOf(ALICE), 98);
        assertEq(token.balanceOf(DEAD), 2);
    }

    function test_transferToDeadCreditsEntireGrossAmount() public {
        _fund(ALICE, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, DEAD, 2);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, DEAD, 98);
        vm.prank(ALICE);
        token.transfer(DEAD, 100);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEAD), 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deadAsSenderConservesBalancesAndSupply() public {
        _fund(DEAD, 100);
        vm.prank(DEAD);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(DEAD), 2);
        assertEq(token.balanceOf(ALICE), 98);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deadSelfTransferCannotExceedGrossBalance() public {
        _fund(DEAD, 100);
        vm.prank(DEAD);
        token.transfer(DEAD, 100);
        assertEq(token.balanceOf(DEAD), 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEAD, 100, 101));
        vm.prank(DEAD);
        token.transfer(DEAD, 101);
        assertEq(token.balanceOf(DEAD), 100);
    }

    function test_transferFromSelfStillSpendsGrossAllowance() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, ALICE, 100);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 98);
        assertEq(token.balanceOf(DEAD), 2);
    }

    function test_insufficientGrossBalanceRevertsBeforeFee() public {
        _fund(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100, 101));
        vm.prank(ALICE);
        token.transfer(BOB, 101);
        _assertFailedTransferBalances(100);
    }

    function test_maximumTransferAmountFailsWithBalanceErrorNotOverflow() public {
        _fund(ALICE, 100);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100, type(uint256).max)
        );
        vm.prank(ALICE);
        token.transfer(BOB, type(uint256).max);
        _assertFailedTransferBalances(100);
    }

    function test_insufficientAllowanceCannotMoveAnyBalance() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 98);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 98, 100));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100);
        assertEq(token.allowance(ALICE, SPENDER), 98);
        _assertFailedTransferBalances(100);
    }

    function test_insufficientBalanceRestoresSpentAllowance() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 101);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100, 101));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 101);
        assertEq(token.allowance(ALICE, SPENDER), 101);
        _assertFailedTransferBalances(100);
    }

    function test_zeroRecipientRejectedEvenForZeroAmount() public {
        _fund(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transfer(address(0), 0);
        _assertFailedTransferBalances(100);
    }

    function test_transferFromZeroRecipientRestoresAllowance() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 100);
        assertEq(token.allowance(ALICE, SPENDER), 100);
        _assertFailedTransferBalances(100);
    }

    function test_zeroSenderAndApproverAndSpenderAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(BOB, 0);
        // transferFrom validates the allowance owner before reaching transfer's sender check.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), BOB, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(ALICE);
        token.approve(address(0), 1);
    }

    function test_constructorRejectsFactoryMismatchZeroAndDead() public {
        vm.expectRevert(KITTY.InvalidFactory.selector);
        new KITTY(address(factory), MANAGER, LAUNCH);
        vm.expectRevert(KITTY.InvalidFactory.selector);
        vm.prank(address(0));
        new KITTY(address(0), MANAGER, LAUNCH);
        vm.expectRevert(KITTY.InvalidFactory.selector);
        vm.prank(DEAD);
        new KITTY(DEAD, MANAGER, LAUNCH);
    }

    function test_constructorRejectsZeroDeadAndFactoryPoolManagers() public {
        vm.expectRevert(KITTY.InvalidPoolManager.selector);
        factory.deploy(address(0), LAUNCH);
        vm.expectRevert(KITTY.InvalidPoolManager.selector);
        factory.deploy(DEAD, LAUNCH);
        vm.expectRevert(KITTY.InvalidPoolManager.selector);
        factory.deploy(address(factory), LAUNCH);
    }

    function test_factoryDistributionIsFullValueWithSingleEvent() public {
        vm.recordLogs();
        _fund(ALICE, 100);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(abi.decode(logs[0].data, (uint256)), 100);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 100);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_registeredDistributorClaimIsFullValue() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _fund(DISTRIBUTOR, SUPPLY / 10);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, SUPPLY / 10);
        assertEq(token.balanceOf(ALICE), SUPPLY / 10);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_wrongLaunchDistributorReceivesNoExemption() public {
        factory.setDistributor(LAUNCH + 1, DISTRIBUTOR);
        _fund(DISTRIBUTOR, 100);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 98);
        assertEq(token.balanceOf(DEAD), 2);
    }

    function test_distributorResolutionReflectsFactoryUpdates() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _fund(DISTRIBUTOR, 200);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100);
        factory.setDistributor(LAUNCH, BOB);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 198);
        assertEq(token.balanceOf(DEAD), 2);
        _fund(BOB, 100);
        vm.prank(BOB);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 298);
        assertEq(token.balanceOf(DEAD), 2);
    }

    function test_poolManagerBuyAndOrdinarySellBothMoveFullValue() public {
        _fund(MANAGER, 100);
        vm.prank(MANAGER);
        token.transfer(ALICE, 100);
        assertEq(token.balanceOf(ALICE), 100);
        vm.prank(ALICE);
        token.transfer(MANAGER, 100);
        assertEq(token.balanceOf(MANAGER), 100);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_approvedRouterSellIntoPoolManagerMovesFullValue() public {
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, MANAGER, 100);
        assertEq(token.balanceOf(MANAGER), 100);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
    }

    function test_privilegedCallersStillRequireAllowance() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _fund(ALICE, 300);
        address[3] memory callers = [address(factory), MANAGER, DISTRIBUTOR];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 100)
            );
            vm.prank(callers[i]);
            token.transferFrom(ALICE, BOB, 100);
            vm.prank(ALICE);
            token.approve(callers[i], 100);
            vm.prank(callers[i]);
            token.transferFrom(ALICE, BOB, 100);
            assertEq(token.allowance(ALICE, callers[i]), 0);
        }
        assertEq(token.balanceOf(BOB), 300);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_unrelatedSpenderIsTaxedEvenWhenFromAddressIsPrivileged() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _fund(MANAGER, 100);
        _fund(DISTRIBUTOR, 100);
        address[3] memory owners = [address(factory), MANAGER, DISTRIBUTOR];
        for (uint256 i; i < owners.length; ++i) {
            vm.prank(owners[i]);
            token.approve(SPENDER, 100);
            vm.prank(SPENDER);
            token.transferFrom(owners[i], ALICE, 100);
            assertEq(token.allowance(owners[i], SPENDER), 0);
        }
        assertEq(token.balanceOf(ALICE), 294);
        assertEq(token.balanceOf(DEAD), 6);
    }

    function test_transfersToFactoryOrDistributorRemainTaxed() public {
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        _fund(ALICE, 200);
        uint256 factoryBefore = token.balanceOf(address(factory));
        vm.startPrank(ALICE);
        token.transfer(address(factory), 100);
        token.transfer(DISTRIBUTOR, 100);
        vm.stopPrank();
        assertEq(token.balanceOf(address(factory)), factoryBefore + 98);
        assertEq(token.balanceOf(DISTRIBUTOR), 98);
        assertEq(token.balanceOf(DEAD), 4);
    }

    function test_failedMalformedAndGasExhaustingLookupsTaxWithoutFreezing() public {
        factory.setDistributor(LAUNCH, ALICE);
        _fund(ALICE, 600);
        for (uint8 mode = 1; mode <= uint8(KittyFactoryMock.LookupMode.ExhaustGas); ++mode) {
            factory.setMode(KittyFactoryMock.LookupMode(mode));
            vm.prank(ALICE);
            assertTrue(token.transfer(BOB, 100));
            assertEq(token.balanceOf(BOB), uint256(mode) * 98);
            assertEq(token.balanceOf(DEAD), uint256(mode) * 2);
        }
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_lookupFailureDoesNotAffectFactoryOrManagerExemptions() public {
        factory.setMode(KittyFactoryMock.LookupMode.ExhaustGas);
        _fund(ALICE, 100);
        vm.prank(ALICE);
        token.transfer(MANAGER, 100);
        vm.prank(MANAGER);
        token.transfer(BOB, 100);
        assertEq(token.balanceOf(BOB), 100);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_factoryWithoutLookupCodeDoesNotFreezeOrdinaryHolders() public {
        vm.prank(SPENDER);
        KITTY direct = new KITTY(SPENDER, MANAGER, type(uint64).max);
        vm.prank(SPENDER);
        direct.transfer(ALICE, 100);
        vm.prank(ALICE);
        direct.transfer(BOB, 100);
        assertEq(direct.balanceOf(BOB), 98);
        assertEq(direct.balanceOf(DEAD), 2);
        assertEq(direct.balanceOf(SPENDER), SUPPLY - 100);
    }

    function test_noPublicMintPauseBlacklistOrSeizeSelectors() public {
        _fund(ALICE, 100);
        // Each probe must have valid ABI arguments: an invalid bool can revert before a
        // dangerous implementation reaches its authorization or state-changing logic.
        bytes[] memory probes = new bytes[](25);
        probes[0] = abi.encodeWithSignature("mint(address,uint256)", ALICE, uint256(100));
        probes[1] = abi.encodeWithSignature("mint(uint256)", uint256(100));
        probes[2] = abi.encodeWithSignature("mint()");
        probes[3] = abi.encodeWithSignature("issue(uint256)", uint256(100));
        probes[4] = abi.encodeWithSignature("setOwner(address)", ALICE);
        probes[5] = abi.encodeWithSignature("transferOwnership(address)", ALICE);
        probes[6] = abi.encodeWithSignature("upgradeTo(address)", ALICE);
        probes[7] = abi.encodeWithSignature("initialize(address)", ALICE);
        probes[8] = abi.encodeWithSignature("unpause()");
        probes[9] = abi.encodeWithSignature("setMinter(address)", ALICE);
        probes[10] = abi.encodeWithSignature("pause()");
        probes[11] = abi.encodeWithSignature("blacklist(address)", ALICE);
        probes[12] = abi.encodeWithSignature("blocklist(address)", ALICE);
        probes[13] = abi.encodeWithSignature("freeze(address)", ALICE);
        probes[14] = abi.encodeWithSignature("freezeAccount(address)", ALICE);
        probes[15] = abi.encodeWithSignature("setBlacklist(address,bool)", ALICE, true);
        probes[16] = abi.encodeWithSignature("setBlacklist(address,bool)", ALICE, false);
        probes[17] = abi.encodeWithSignature("setBlocked(address,bool)", ALICE, true);
        probes[18] = abi.encodeWithSignature("setBlocked(address,bool)", ALICE, false);
        probes[19] = abi.encodeWithSignature("lock(address)", ALICE);
        probes[20] = abi.encodeWithSignature("disableTransfers()");
        probes[21] = abi.encodeWithSignature("setTransfersEnabled(bool)", true);
        probes[22] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        probes[23] = abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, uint256(100));
        probes[24] = abi.encodeWithSignature("seize(address)", ALICE);
        address[2] memory callers = [address(factory), SPENDER];
        for (uint256 i; i < probes.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool success,) = address(token).call(probes[i]);
                assertFalse(success, string.concat("admin probe ", vm.toString(i), " unexpectedly succeeded"));
                _assertFailedTransferBalances(100);
                assertEq(token.balanceOf(address(factory)), SUPPLY - 100);
                assertEq(token.balanceOf(SPENDER), 0);
                assertEq(token.allowance(ALICE, callers[j]), 0);
            }
        }
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 98);
        assertEq(token.balanceOf(DEAD), 2);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4, "DELEGATECALL opcode");
            assertTrue(opcode != 0xf2, "CALLCODE opcode");
            assertTrue(opcode != 0xff, "SELFDESTRUCT opcode");
        }
    }

    function testFuzz_transferConservesSupplyAndChargesFloorFee(uint256 holding, uint256 value) public {
        holding = bound(holding, 0, SUPPLY);
        value = bound(value, 0, holding);
        _fund(ALICE, holding);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, value));
        uint256 fee = value * 200 / 10_000;
        assertEq(token.balanceOf(ALICE), holding - value);
        assertEq(token.balanceOf(BOB), value - fee);
        assertEq(token.balanceOf(DEAD), fee);
        assertEq(
            token.balanceOf(address(factory)) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(DEAD),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromConservesValueAndUsesGrossAllowance(uint256 value, uint256 approved) public {
        value = bound(value, 0, SUPPLY);
        if (approved < value) approved = value;
        _fund(ALICE, value);
        vm.prank(ALICE);
        token.approve(SPENDER, approved);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, value));
        assertEq(token.allowance(ALICE, SPENDER), approved == type(uint256).max ? approved : approved - value);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB) + token.balanceOf(DEAD), value);
        assertEq(token.balanceOf(DEAD), value * 200 / 10_000);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedOverdrawPreservesAllowanceAndBalances(uint256 holding, uint256 excess) public {
        holding = bound(holding, 0, SUPPLY);
        excess = bound(excess, 1, SUPPLY);
        uint256 value = holding + excess;
        _fund(ALICE, holding);
        vm.prank(ALICE);
        token.approve(SPENDER, value);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, holding, value));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, value);
        assertEq(token.allowance(ALICE, SPENDER), value);
        _assertFailedTransferBalances(holding);
    }

    function _fund(address to, uint256 amount) private {
        assertTrue(factory.move(token, to, amount));
    }

    function _assertFailedTransferBalances(uint256 aliceBalance) private view {
        assertEq(token.balanceOf(ALICE), aliceBalance);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
