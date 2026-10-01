# Vendored dependency

Upstream: https://github.com/transmissions11/solmate

Pinned commit: `4b47a19038b798b4a33d9749d25e570443520647`.

Only the unmodified `src/auth/Owned.sol` needed to compile the real PoolManager integration test is included, together with the upstream AGPL-3.0-only `LICENSE`. This is the solmate commit pinned by v4-core at commit `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`. No submodule or upstream build configuration is included.

This dependency is used by local tests only; the production KITTY contract does not import it.

SHA-256 of the imported files:

```text
20b067f86de375aae6db0f283ab2e65de24d537733b89bd58432c101259d84cf  LICENSE
8ac2f2dc41ab8012e93adb3791326ffa1e4059a20c306a777109dd81816b9125  src/auth/Owned.sol
```
