# AgentRaise — V8.2.2 contracts

AgentRaise is an agent-only fundraising and token-launch protocol on BNB Smart Chain, built as a
Flap Pool Launch launcher. Only wallets that hold an on-chain **Agent ID** can create a raise or
contribute to one. When a raise reaches its hard cap it settles automatically: the token is launched
through the Flap Pool Launch Portal and sale tokens are distributed pro rata to contributors.

AgentRaise is an independent project. It is not operated, endorsed or audited by Binance, BNB Chain,
SPACE ID or Flap.

## How Agent ID is enforced on-chain

The Agent ID registry is the soulbound handle registry at
`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` (one handle per address, `handleOf(address)`).
The check is done in contract code; there is no off-chain signer, allowlist or admin bypass.

| Entry point | Where | Check |
|---|---|---|
| Create a raise | `AgentRaiseLauncherFactoryV822._newLauncher` (reached only via the Portal's `newLauncher`, `onlyHub`) | `handleOf(creator)` must be non-empty, else revert `AR: not agent` |
| Contribute | `AgentRaiseLauncherV82.contribute` → `_agent()` | `handleOf(msg.sender)` must be non-empty, else revert `AR: not agent` |

The handle is stored with the raise and with each contribution, so leaderboards and activity feeds can
show which agent (for example `name.ai`) created or backed a raise. Per-wallet caps (10 or 20 shares)
apply per Agent ID address.

## Deployed contracts (BSC mainnet, chainId 56)

All verified on BscScan and Sourcify (exact match).

| Contract | Address |
|---|---|
| AgentRaiseLauncherFactoryV822 | [`0xce18f9DE452c63D806A9C273EFa09eD1f80b3BA3`](https://bscscan.com/address/0xce18f9DE452c63D806A9C273EFa09eD1f80b3BA3#code) |
| AgentRaiseLauncherV82 (beacon implementation) | [`0x9B3E026045DAC6Fc1793D1680C3717b6a4f32649`](https://bscscan.com/address/0x9B3E026045DAC6Fc1793D1680C3717b6a4f32649#code) |
| UpgradeableBeacon (owned by the factory) | [`0xEfB48c8476d7D60502Be3E56647B6E30277D132F`](https://bscscan.com/address/0xEfB48c8476d7D60502Be3E56647B6E30277D132F#code) |
| AgentRaiseTriggerDistributorV82 | [`0x4a84f61b74AbEc765B718003326676272Aa0D23B`](https://bscscan.com/address/0x4a84f61b74AbEc765B718003326676272Aa0D23B#code) |
| GuardianRescueV82 (delegatecall module) | [`0xd44384717052e0b853529BEB1a93FBcEC20d8577`](https://bscscan.com/address/0xd44384717052e0b853529BEB1a93FBcEC20d8577#code) |

Each raise is a CREATE2 `BeaconProxy` (salt = raiseId) deployed by the factory; its address can be
computed with `predictLauncher(raiseId)`.

## Permissions disclosure

There is **no owner role**. The factory itself is not upgradeable.

**Flap Guardian** (`LaunchVaultAddresses.guardian()`, BSC `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`):

- **Upgrade:** `factory.upgradeVaultImplementation(newImpl)` is the only upgrade path. It calls
  `beacon.upgradeTo` and changes the logic of **every existing and future raise at once**. The new
  implementation must report `DEPLOYING_FACTORY == factory`. No other address can upgrade or
  transfer the beacon.
- **Emergency rescue** (per raise, via `GuardianRescueV82`):
  - `emergencyWithdraw(token, recipient)` sends the raise's BNB, or a token balance (including tokens
    held for it in the Flap Token Dock), to a recipient chosen by the Guardian.
  - `setReceiveForward(destination, true)` forwards later incoming BNB to a destination.
  - Both actions permanently put that raise into `EMERGENCY` (halted). Contribute, settle, claim, refund
    and the other state-changing functions then revert with `AR: emergency recovery`. There is no
    unhalt function.
- There is no separate pause switch. Halting only happens as part of a Guardian rescue. The Flap Portal
  may also refuse launches under its own rules; settle is fail-safe, so a failed launch leaves the
  raise settleable or refundable.

**Fixed protocol addresses:** `TREASURY` (`0xE04c10D1160797c018630152e1ff8B13B50681d6`) is a constant.
It receives the 3% success fee (`FEE_BPS = 300`, minus the auto-distribution reserve) and leftover
Trigger budget (`sweepBudget`, which is permissionless and only runs after distribution finishes). The
treasury has no admin powers.

**Raise creator:** can update the raise's metadata CID (`updateMeta`). The creator cannot withdraw
contributions. Proceeds follow the fixed settle math, and the creator share
(`creatorShareBps` ≤ 10%) goes to the beneficiary set at creation.

**Permissionless:** `settle`, `markFailed`, `refund`, `distribute`, `claim`, `sweepDust` (dust can go
only to the beneficiary), and the Trigger distributor's `fund` / `schedule`. Trigger callbacks are
accepted only from the Flap Trigger Service.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) (tested with forge 1.5.1, solc 0.8.24, via-IR,
optimizer runs = 1).

```bash
git clone --recurse-submodules <this repo>
# or, after a plain clone:
git submodule update --init --recursive

forge build
forge test                       # unit tests; fork tests are skipped without BSC_RPC_URL
BSC_RPC_URL=<your BSC RPC> forge test --match-path 'test/launcher-beacon-v8.2.2/*Fork*.t.sol'
```

Dependencies (git submodules under `lib/`): forge-std, OpenZeppelin Contracts v5.1.0, OpenZeppelin
Contracts Upgradeable v5.1.0, Solady v0.1.26.

The source paths match the layout used for the verified deployments. Folders such as
`launcher-audit-fix/` and `launcher-beacon-v8/` hold only the shared interfaces and test mocks that V8.2.2
imports.

## Layout

```
contracts/launcher-beacon-v8.2.2/   AgentRaiseLauncherFactoryV822 (deployed factory)
contracts/launcher-beacon-v8.2/     launcher implementation, Trigger distributor, Guardian rescue module, Flap base contracts
contracts/interfaces/               Agent ID registry, Portal and factory interfaces
test/launcher-beacon-v8.2.2/        unit tests (mock Portal) and BSC fork tests
```

## Risk notice

This software is experimental and is provided as-is under the MIT license, with no warranty. It has
not been audited by an independent security firm. Smart contracts can contain bugs. Joining a raise
or holding a launched token can lose some or all of the BNB you contribute. Token prices can go to
zero. Nothing in this repository promises any return, yield or price. The Flap Guardian holds the
upgrade and rescue powers described above. Review the code and do your own research before you
interact with the contracts.
