# KITTY

KITTY (`KITTY`) is an ERC-20 token with 18 decimals. Its constructor mints exactly
1,000,000,000 tokens (`1000000000000000000000000000` base units) to the deploying
address once. There is no subsequent mint, owner, upgrade, pause, blacklist,
seizure, fee setter, or holder-burn function.

## Transfer economics and assumptions

An ordinary `transfer(to, amount)` or `transferFrom(from, to, amount)` debits the
gross `amount`, sends `floor(amount / 50)` to
`0x000000000000000000000000000000000000dEaD`, and sends the remainder to `to`.
For example, sending 100 KITTY delivers 98 KITTY and puts 2 KITTY at the dead
address. Delegated transfers require allowance for the **gross** amount.

The dead-address fee is a transfer, not an ERC-20 supply burn: `totalSupply()`
always remains `1e27`. The dead address is conventionally considered inaccessible;
the token has no recovery mechanism or special authority over its balance.

The pinned launch checks require whole distributions and exact inbound Uniswap
v4 settlement. The token retains these launch exceptions; PoolManager payouts
pay the same 2% fee as ordinary transfers:

| Transfer condition | Fee |
| --- | --- |
| Caller is the constructor-configured factory | None |
| Destination is the configured PoolManager, including ordinary traders selling | None |
| Caller is the configured PoolManager, paying another address | 2%, rounded down |
| Caller is `factory.distributorOf(launchNumber)` | None |
| Any other transfer or transferFrom | 2%, rounded down |

These conditions apply for the token's lifetime, including factory remainder
distributions and later swaps/claims. They cannot be changed through KITTY.
Being an exempt caller never bypasses ERC-20 balance or allowance checks.
Merely sending to the factory/distributor, or spending their tokens as an
unrelated approved caller, does not grant an exception. Registering the
PoolManager itself as the distributor cannot exempt its payouts.

PoolManager payouts include swaps, liquidity withdrawals, protocol-fee
withdrawals, and ERC-6909 claim redemptions. A gross payout of 1,000 KITTY debits
the manager by 1,000, credits the recipient with 980, and credits the dead
address with 20. Manager accounting still settles the gross amount; recipient
receipts are **not** the gross amount quoted by the pool. Selling the actual
received 980 KITTY pays all 980 to the manager and settles normally.

This closes the reported permissionless `sync` / `settle` / `take` relay:
depositing 1,000 and taking it to another wallet now charges 20 KITTY on payout.
Wrapping into ERC-6909 claims remains full-value, but redemption is taxed.
Transfers of claims themselves do not call KITTY and cannot be taxed by KITTY.
The manager uses the same token transfer call for these payouts and swap
receipts, so the token does not grant an exemption based on a claimed purpose.

Rounding is in base units: amounts below 50 base units have zero fee; 50 and
51 units each have a 1-unit fee. Splitting amounts can therefore reduce rounding
fees; there is no minimum transfer or rounding-up surcharge. Zero transfers
succeed and emit a zero-value `Transfer`. An ordinary self-transfer still
requires the gross balance and loses only its fee. A transfer to the dead
address credits it the full amount. Nonzero fees emit a `Transfer` to the dead
address followed by a `Transfer` of the net amount. Zero-fee transfers emit one
event. Transfers to/from the zero address are rejected.

Approvals use vendored OpenZeppelin ERC-20 behavior, including overwriting the
previous allowance, zero revocation, and an unchanged `uint256.max` allowance
after spending. Applications should request only the allowance they need and
account for the usual allowance replacement transaction-ordering race.

## Deployment parameters

Deployable artifact: `src/KITTY.sol:KITTY`.

```solidity
constructor(address factory_, address poolManager_, uint64 launchNumber_)
```

| Argument | Launch value and validation |
| --- | --- |
| `factory_` | `$factory`; must equal constructor `msg.sender`, and cannot be zero or the dead address |
| `poolManager_` | `$poolManager`; cannot be zero, the dead address, or the factory |
| `launchNumber_` | `$launchNumber`; uint64 identifier used to resolve the distributor |

Constructor arguments are static ABI values, in the order above. There are no
initialization calls, constructor value, other application contracts, deployment
keys, or broadcast scripts. The factory is the deployer and initially holds the
whole supply; deployment itself performs no distribution. A launcher preparing a
manifest should use name/symbol `KITTY`, decimals `18`, and the exact base-unit
supply above. No manifest economics are invented here.

The distributor address is intentionally resolved during transfers because its
address depends on the deployed token. Its view call is limited to 30,000 gas
and accepts only an exact 32-byte ABI address result. A failed, missing,
malformed, or over-budget response grants no distributor exemption; ordinary
holder transfers continue with the usual fee. The response is fetched with
`STATICCALL` and at most 32 bytes are copied. No lookup happens for factory
operations, deposits into PoolManager, or its taxed payouts.

Factory and PoolManager addresses are configuration, not on-chain authenticity
checks. No network-specific addresses were supplied or verified. Before launch,
the operator must verify the intended chain, canonical factory and PoolManager,
correct launch identifier, and the factory's lookup ABI/gas compatibility. An
EOA can technically deploy with itself as `factory_`, but cannot supply the
required distributor lookup for a network launch. The trusted factory's mapping
or upgrades can change the resolved distributor; KITTY provides no authority to
restrict such a factory change.

The network deployer remains responsible for correct launch economics,
distributor registration, distribution, pool initialization/seeding, and source
verification. Integrators must advertise the exemptions and handle net receipt
amounts for ordinary transfers and PoolManager payouts; pools other than the
configured PoolManager are taxed in both directions. Routers and frontends must
measure actual receipts, enforce minimum outputs against net receipts, and
quote the payout fee for buys, liquidity withdrawals, and claim redemptions.
A router that assumes a gross quoted output reaches the recipient unchanged
is incompatible without adapting that assumption. Factory/distributor callers
remain trusted exceptions, and the token does not promise a fee on transfers
of external wrapper claims. There are no token keepers, admin keys, or adjustable
operational parameters. Tokens sent to KITTY itself have no rescue path. Native ETH is not
accepted by a payable entrypoint and forcibly sent ETH has no withdrawal path.

## Build and tests

Use Foundry with Solidity **0.8.26**, pinned by version in `foundry.toml`:

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are vendored as ordinary files under `lib/`, with
upstream versions/commits, checksums, and licenses recorded beside them. No
submodules, package installation, RPC, environment variables, FFI, or filesystem
cheatcodes are required. With the pinned compiler installed, verification needs
no network. Compiler metadata uses `bytecode_hash = "none"`.

Local revision validation passed `forge build`, `forge test` (50 tests), and
`forge fmt --check`. The suite includes three fuzz tests with 512 cases each
and three stateful invariants over 8,192 handler calls.

Unit and fuzz tests cover token accounting, rounding, events, approval behavior,
failure atomicity, configuration validation, and launch exceptions. Stateful
invariants exercise sequences of direct and delegated transfers and check fixed
supply, conservation of balances, and dead-address fee accounting. The local
launch integration uses a real vendored Uniswap v4 PoolManager to check complete
swarm distribution/claims, single-sided seeding, a trader buying and selling
back their actual net receipt, and taxed liquidity withdrawals. The relay and
ERC-6909 redemption regressions reproduce the reviewer's proof with a real
PoolManager; both now charge a fee. An underpaid sell must revert atomically
without changing either party's balances or the previously collected fee.

The pinned `Token.protected.t.sol` belongs to the external launch verifier: it
requires that verifier's launch infrastructure, manifest bytecode, and
environment parameters, which are not provided as a runnable project here. The
local tests exercise the relevant behavior without modifying that input or
depending on its environment. Passing local checks does not attest that external
deployment configuration.

A separate agent reviewed the token's accounting, authorization, distributor
lookup, and compiled opcodes during implementation. This is not an independent
security audit. Slither and Mythril were not run. The network's independent
adversarial review and deployment validation remain release responsibilities;
no transactions were submitted by this assignment.
