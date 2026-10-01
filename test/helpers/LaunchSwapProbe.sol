// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KITTY} from "../../src/KITTY.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Local test harnesses only; these contracts are not deployment tooling or trading routers.
abstract contract KittySettlementHarness is IUnlockCallback {
    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;

    error OnlyController();
    error OnlyManager();

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != address(manager)) revert OnlyManager();
        _;
    }

    receive() external payable {}

    function _settle(Currency currency, int128 delta, bool shortPay) internal {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                // A deliberate one-unit short payment tests PoolManager's debt enforcement.
                if (shortPay) --amount;
                require(IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        }
    }
}

contract KittyFactoryV4Harness is KittySettlementHarness {
    mapping(uint64 => address) public distributorOf;

    constructor(IPoolManager manager_) KittySettlementHarness(manager_) {}

    function deploy(uint64 launchNumber) external onlyController returns (KITTY) {
        return new KITTY(address(this), address(manager), launchNumber);
    }

    function setDistributor(uint64 launchNumber, address distributor) external onlyController {
        distributorOf[launchNumber] = distributor;
    }

    function move(KITTY token, address recipient, uint256 amount) external onlyController {
        require(token.transfer(recipient, amount));
    }

    function seed(PoolKey calldata key, uint128 liquidity) external onlyController returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(key, liquidity)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 0, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        _settle(key.currency0, delta.amount0(), false);
        _settle(key.currency1, delta.amount1(), false);
        return abi.encode(delta);
    }
}

/// @dev This trader has no fee exemption. KITTY must settle its payment to PoolManager in full.
contract KittyTraderV4Harness is KittySettlementHarness {
    constructor(IPoolManager manager_) KittySettlementHarness(manager_) {}

    function swap(PoolKey calldata key, bool zeroForOne, uint256 input, bool shortPay)
        external
        onlyController
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, input, shortPay)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 input, bool shortPay) =
            abi.decode(data, (PoolKey, bool, uint256, bool));
        require(input <= uint256(type(int256).max));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(input),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settle(key.currency0, delta.amount0(), shortPay);
        _settle(key.currency1, delta.amount1(), shortPay);
        return abi.encode(delta);
    }
}
