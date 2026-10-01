// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KITTY} from "src/KITTY.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

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
            // Manager pays `to`: caller == poolManager so KITTY charges no fee either.
            manager.take(currency, to, amount);
        } else {
            manager.mint(to, id, amount);
        }
        return "";
    }
}

contract KittyPoolManagerRelayTest is Test {
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

    /// @dev The spec says every transfer pays 2% to the dead address. Alice moves 1000 KITTY to Bob
    /// through the PoolManager instead of calling transfer, and Bob receives all 1000.
    function test_walletToWalletViaPoolManagerPaysNoFee() public {
        vm.prank(ALICE);
        relay.run(Relay.Action.TakeTo, ALICE, BOB, 1_000 ether);

        assertEq(token.balanceOf(ALICE), 1_000 ether, "alice debited gross");
        assertEq(token.balanceOf(address(manager)), 0, "manager keeps nothing");
        // Expected under the spec: Bob 980, DEAD 20. Actual: Bob 1000, DEAD 0.
        assertEq(token.balanceOf(DEAD), 20 ether, "no fee reached the dead address");
        assertEq(token.balanceOf(BOB), 980 ether, "bob received the gross amount");
    }

    /// @dev KITTY can be wrapped into PoolManager ERC-6909 claims fee-free, the claims change hands
    /// fee-free any number of times, and whoever holds them unwraps fee-free. A permanent fee-free
    /// rail for the token exists from the moment the pool manager is exempted.
    function test_erc6909ClaimsAreAPermanentFeeFreeWrapper() public {
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

        assertEq(token.balanceOf(CAROL) + token.balanceOf(DEAD), 1_000 ether, "value was not conserved");
        // Three hops of value moved; the spec implies a fee should have reached the dead address.
        assertGt(token.balanceOf(DEAD), 0, "no fee was ever paid on three hops");
    }
}
