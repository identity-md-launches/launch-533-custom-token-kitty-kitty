// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KITTY} from "../src/KITTY.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {KittySettlementHarness, KittyFactoryV4Harness, KittyTraderV4Harness} from "./helpers/LaunchSwapProbe.sol";

/// @notice Offline integration with the real Uniswap v4 PoolManager and its flash accounting.
contract KITTYLaunchTest is Test {
    uint64 private constant LAUNCH_NUMBER = 42;
    uint128 private constant LIQUIDITY = 1e24;
    address private constant DISTRIBUTOR = address(0xD157);
    address private constant CLAIMANT = address(0xC1A1);
    address private constant REQUESTER = address(0xA11CE);

    PoolManager private manager;
    KittyFactoryV4Harness private factory;
    KittyTraderV4Harness private trader;
    KITTY private token;
    PoolKey private key;

    function setUp() public {
        manager = new PoolManager(address(this));
        factory = new KittyFactoryV4Harness(manager);
        trader = new KittyTraderV4Harness(manager);
        token = factory.deploy(LAUNCH_NUMBER);
        factory.setDistributor(LAUNCH_NUMBER, DISTRIBUTOR);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.deal(address(trader), 10 ether);
    }

    function testLaunchDistributionAndClaimDeliverGrossAmounts() public {
        uint256 supply = token.INITIAL_SUPPLY();
        assertEq(token.balanceOf(address(factory)), supply);
        uint256 swarm = supply / 10;
        factory.move(token, DISTRIBUTOR, swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        factory.move(token, REQUESTER, supply - swarm);
        assertEq(token.balanceOf(REQUESTER), supply - swarm);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(token.DEAD()), 0);
        assertEq(token.totalSupply(), supply);

        // Distribution does not give the claimant a permanent transfer exemption.
        vm.prank(CLAIMANT);
        assertTrue(token.transfer(REQUESTER, 100 ether));
        assertEq(token.balanceOf(token.DEAD()), 2 ether);
        assertEq(token.balanceOf(REQUESTER), supply - swarm + 98 ether);
        assertEq(token.totalSupply(), supply);
    }

    function testSingleSidedSeedAndOrdinaryTraderBuyThenSellSettleExactly() public {
        uint256 swarm = token.INITIAL_SUPPLY() / 10;
        factory.move(token, DISTRIBUTOR, swarm);
        uint256 factoryBefore = token.balanceOf(address(factory));
        uint256 seeded = _seed();
        assertGt(seeded, 0);
        assertEq(token.balanceOf(address(factory)), factoryBefore - seeded);
        assertEq(token.balanceOf(address(manager)), seeded);
        assertEq(address(manager).balance, 0);
        assertEq(token.balanceOf(token.DEAD()), 0);

        factory.move(token, REQUESTER, factoryBefore - seeded);
        assertEq(token.balanceOf(REQUESTER), factoryBefore - seeded);

        BalanceDelta buy = trader.swap(key, true, 1 ether, false);
        assertEq(int256(buy.amount0()), -int256(1 ether));
        assertGt(int256(buy.amount1()), 0);
        uint256 bought = uint128(buy.amount1());
        assertEq(token.balanceOf(address(trader)), bought);
        assertEq(token.balanceOf(address(manager)), seeded - bought);
        assertEq(address(trader).balance, 9 ether);
        assertEq(address(manager).balance, 1 ether);
        assertEq(token.balanceOf(token.DEAD()), 0);

        BalanceDelta sell = trader.swap(key, false, bought, false);
        assertEq(int256(sell.amount1()), -int256(bought));
        assertGt(int256(sell.amount0()), 0);
        uint256 receivedEth = uint128(sell.amount0());
        assertLt(receivedEth, 1 ether); // The pool's liquidity-provider fee remains in the pool.
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(manager)), seeded);
        assertEq(address(trader).balance, 9 ether + receivedEth);
        assertEq(address(manager).balance, 1 ether - receivedEth);
        assertEq(token.balanceOf(token.DEAD()), 0);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testUnderpaidSellRevertsAtomicallyAndFullSettlementStillSucceeds() public {
        _seed();
        trader.swap(key, true, 1 ether, false);
        uint256 bought = token.balanceOf(address(trader));
        uint256 managerTokens = token.balanceOf(address(manager));
        uint256 traderEth = address(trader).balance;
        uint256 managerEth = address(manager).balance;

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, false, bought, true);
        assertEq(token.balanceOf(address(trader)), bought);
        assertEq(token.balanceOf(address(manager)), managerTokens);
        assertEq(address(trader).balance, traderEth);
        assertEq(address(manager).balance, managerEth);
        assertEq(token.balanceOf(token.DEAD()), 0);

        trader.swap(key, false, bought, false);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(address(manager)), managerTokens + bought);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    function testUnsolicitedUnlockCallbacksFail() public {
        vm.expectRevert(KittySettlementHarness.OnlyManager.selector);
        factory.unlockCallback("");
        vm.expectRevert(KittySettlementHarness.OnlyManager.selector);
        trader.unlockCallback("");
        assertEq(token.balanceOf(address(factory)), token.INITIAL_SUPPLY());
    }

    function _seed() private returns (uint256 seeded) {
        manager.initialize(key, uint160(1 << 96));
        BalanceDelta seedDelta = factory.seed(key, LIQUIDITY);
        assertEq(int256(seedDelta.amount0()), 0);
        assertLt(int256(seedDelta.amount1()), 0);
        seeded = uint256(-int256(seedDelta.amount1()));
    }
}
