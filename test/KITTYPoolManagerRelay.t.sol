// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KITTY} from "src/KITTY.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

/// @dev Minimal stand-in for the launch factory: deploys KITTY as msg.sender and answers distributorOf.
contract RelayFactory {
    mapping(uint64 => address) public distributorOf;

    function deploy(address poolManager, uint64 launchNumber) external returns (KITTY) {
        return new KITTY(address(this), poolManager, launchNumber);
    }

    function move(KITTY token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }
}

/// @dev An ordinary, non-exempt contract any holder can deploy. It never swaps: it only uses the
/// PoolManager's flash accounting (sync / settle / take / mint / burn) as a transfer relay.
contract Relay is IUnlockCallback {
    IPoolManager immutable manager;
    KITTY immutable token;

    enum Action {
        TakeTo,
        MintClaims,
        BurnClaimsAndTake
    }

    constructor(IPoolManager manager_, KITTY token_) {
        manager = manager_;
        token = token_;
    }

    function run(Action action, address from, address to, uint256 amount) external {
        manager.unlock(abi.encode(action, from, to, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Action action, address from, address to, uint256 amount) =
            abi.decode(data, (Action, address, address, uint256));
        Currency currency = Currency.wrap(address(token));
        uint256 id = uint256(uint160(address(token)));
        if (action == Action.BurnClaimsAndTake) {
            // `from` approved this relay as an ERC-6909 operator; burn its claims and take real tokens to `to`.
            manager.burn(from, id, amount);
            manager.take(currency, to, amount);
            return "";
        }
        // Pay the manager with the holder's tokens: `to == poolManager` so KITTY charges no fee.
        manager.sync(currency);
        require(token.transferFrom(from, address(manager), amount));
        manager.settle();
        if (action == Action.TakeTo) {
            // Manager payouts debit the gross amount and deliver the net amount after KITTY's fee.
            manager.take(currency, to, amount);
        } else {
            manager.mint(to, id, amount);
        }
        return "";
    }
}

contract KittyPoolManagerRelayTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    PoolManager manager;
    RelayFactory factory;
    KITTY token;
    Relay relay;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new RelayFactory();
        token = factory.deploy(address(manager), 42);
        relay = new Relay(manager, token);
        factory.move(token, ALICE, 2_000 ether);
        vm.prank(ALICE);
        token.approve(address(relay), type(uint256).max);
    }

    /// @dev Routing an ordinary transfer through PoolManager still charges the 2% fee on payout.
    function test_walletToWalletViaPoolManagerPaysFeeOnPayout() public {
        vm.prank(ALICE);
        relay.run(Relay.Action.TakeTo, ALICE, BOB, 1_000 ether);

        assertEq(token.balanceOf(ALICE), 1_000 ether, "alice debited gross");
        assertEq(token.balanceOf(address(manager)), 0, "manager keeps nothing");
        assertEq(token.balanceOf(DEAD), 20 ether, "dead receives the fee");
        assertEq(token.balanceOf(BOB), 980 ether, "bob receives the net amount");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Moving ERC-6909 claims does not move KITTY; redeeming those claims charges the payout fee.
    function test_erc6909ClaimRedemptionPaysFeeAfterClaimsChangeHands() public {
        uint256 id = uint256(uint160(address(token)));

        vm.prank(ALICE);
        relay.run(Relay.Action.MintClaims, ALICE, ALICE, 1_000 ether);
        assertEq(manager.balanceOf(ALICE, id), 1_000 ether, "wrap arrived short");

        // Claims move Alice -> Bob -> Carol with no KITTY transfer at all.
        vm.prank(ALICE);
        manager.transfer(BOB, id, 1_000 ether);
        vm.prank(BOB);
        manager.transfer(CAROL, id, 1_000 ether);

        // Carol unwraps to her wallet.
        vm.prank(CAROL);
        manager.setOperator(address(relay), true);
        vm.prank(CAROL);
        relay.run(Relay.Action.BurnClaimsAndTake, CAROL, CAROL, 1_000 ether);

        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(CAROL), 980 ether, "carol receives the net amount");
        assertEq(token.balanceOf(DEAD), 20 ether, "redemption charges the fee exactly once");
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(manager.balanceOf(ALICE, id), 0);
        assertEq(manager.balanceOf(BOB, id), 0);
        assertEq(manager.balanceOf(CAROL, id), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_insufficientDepositAllowanceRevertsUnlockAtomically() public {
        uint256 id = uint256(uint160(address(token)));
        vm.prank(ALICE);
        token.approve(address(relay), 999 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(relay), 999 ether, 1_000 ether
            )
        );
        vm.prank(ALICE);
        relay.run(Relay.Action.MintClaims, ALICE, BOB, 1_000 ether);

        assertEq(token.allowance(ALICE, address(relay)), 999 ether);
        assertEq(token.balanceOf(ALICE), 2_000 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(relay)), 0);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 2_000 ether);
        assertEq(manager.balanceOf(ALICE, id), 0);
        assertEq(manager.balanceOf(BOB, id), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroRecipientRestoresRedeemedClaimsAndRetryPaysFee() public {
        uint256 id = uint256(uint160(address(token)));
        vm.prank(ALICE);
        relay.run(Relay.Action.MintClaims, ALICE, ALICE, 1_000 ether);
        vm.prank(ALICE);
        manager.approve(address(relay), id, 1_000 ether);

        // PoolManager wraps the token's receiver error with the failed transfer's exact context.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(token),
                IERC20Minimal.transfer.selector,
                abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        vm.prank(ALICE);
        relay.run(Relay.Action.BurnClaimsAndTake, ALICE, address(0), 1_000 ether);

        assertEq(manager.balanceOf(ALICE, id), 1_000 ether);
        assertEq(manager.allowance(ALICE, address(relay), id), 1_000 ether);
        assertEq(token.allowance(ALICE, address(relay)), type(uint256).max);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(address(manager)), 1_000 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(relay)), 0);
        assertEq(token.balanceOf(address(factory)), SUPPLY - 2_000 ether);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(ALICE);
        relay.run(Relay.Action.BurnClaimsAndTake, ALICE, BOB, 1_000 ether);

        assertEq(manager.balanceOf(ALICE, id), 0);
        assertEq(manager.allowance(ALICE, address(relay), id), 0);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(BOB), 980 ether);
        assertEq(token.balanceOf(DEAD), 20 ether);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_relayPayoutMatchesDirectTransferForRecipientAliases(
        uint256 amount,
        uint256 recipientSeed,
        bool useClaims
    ) public {
        amount = bound(amount, 0, 2_000 ether);
        address[3] memory recipients = [ALICE, BOB, DEAD];
        address recipient = recipients[recipientSeed % recipients.length];
        uint256 snapshot = vm.snapshotState();

        vm.prank(ALICE);
        assertTrue(token.transfer(recipient, amount));
        uint256 aliceDirect = token.balanceOf(ALICE);
        uint256 bobDirect = token.balanceOf(BOB);
        uint256 deadDirect = token.balanceOf(DEAD);
        assertTrue(vm.revertToState(snapshot));

        uint256 id = uint256(uint160(address(token)));
        if (useClaims) {
            vm.prank(ALICE);
            relay.run(Relay.Action.MintClaims, ALICE, ALICE, amount);
            vm.prank(ALICE);
            manager.setOperator(address(relay), true);
            vm.prank(ALICE);
            relay.run(Relay.Action.BurnClaimsAndTake, ALICE, recipient, amount);
        } else {
            vm.prank(ALICE);
            relay.run(Relay.Action.TakeTo, ALICE, recipient, amount);
        }

        assertEq(token.balanceOf(ALICE), aliceDirect);
        assertEq(token.balanceOf(BOB), bobDirect);
        assertEq(token.balanceOf(DEAD), deadDirect);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(manager.balanceOf(ALICE, id), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
