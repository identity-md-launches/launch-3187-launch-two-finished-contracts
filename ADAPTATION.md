# Adaptation for the Ethereum launch

Launch kind: `evm_contracts` on Ethereum (chain id 1). It deploys two contracts, in this order, and
nothing else. There is no token, pool, owner, website or fee.

| # | Contract | Constructor arguments |
| --- | --- | --- |
| 1 | `Judge` (`src/Judge.sol`) | oracleSigner_ `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, intake_ `0xa43e6f75ee006411f79ac1c84120606c2330de82`, asset_ `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, panelSize_ `100`, quorum_ `51` |
| 2 | `JudgeEthDoor` (`src/JudgeEthDoor.sol`) | judge_ `$contract:Judge`, asset_ `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, poolManager_ `0x000000000004444c5dc75cb358380d2e3de08a90`, poolFee_ `10000`, poolTickSpacing_ `200` |

## Changes

| File | Change | Why |
| --- | --- | --- |
| `test/Launch.t.sol` (new) | Deploys both contracts with the brief's exact arguments, in launch order, on an empty chain 1. It checks every stored argument and that the door points at the `Judge` launched before it. It checks that neither contract has an owner or admin. It runs the protected floor's opcode scan on both runtimes, pins Judge's question wording byte for byte, and checks that an ask before the live Intake is reachable reverts without opening a case. | A rehearsal of this launch that ships in the repository. It changes no contract. |
| `ADAPTATION.md` (new) | This file. | The acceptance criteria ask for it. |

**No source file changed.** `src/`, `foundry.toml`, `remappings.txt`, `lib/` and the site are as they were at
commit `72ba6cd`. Neither contract needed a launch change:

- Both constructors are nonpayable and take only static arguments: address, uint16 and uint24. That is five
  arguments each, well under 16. They call nothing and need no code at any address, so they run on an empty
  chain.
- Neither contract has an owner, admin, setter, proxy, upgrade path, fee, mint, pause, DELEGATECALL, CALLCODE or
  SELFDESTRUCT.
- `foundry.toml` already sets `bytecode_hash = "none"`. Every library function the contracts call is internal,
  so the bytecode needs no linking.

## Bytecode

Built with the project's own configuration (solc 0.8.26, cancun, optimizer 200, `bytecode_hash = "none"`).
These hashes are keccak-256 of the creation code without constructor arguments:

| Contract | Creation code | Runtime |
| --- | --- | --- |
| `Judge` | `0x1829917ebd076c11eb136613f10230beab3b22fa8c9d9af0871aaec263be1b55` | `0x216c3a257db0047070df1b54ad3744f06b648efcfedc729cb8ae91f84dd8eed4` |
| `JudgeEthDoor` | `0x65b6f25931cf8685de79b0cdb856a43112a7d3ee297d43124ecf1c9b75de68d6` | `0xaaeffc609f11767966ec9e32257cdf42d1aa64268527483d33fb7a039795a411` |

I rebuilt commit `72ba6cd` from `git archive` in a different directory and got the same creation-code hashes.
No source changed, so the bytecode this launch deploys is the bytecode of `72ba6cd`. The runtime hashes do not
cover the immutables: those are filled in at deployment from the constructor arguments.

I did not deploy anything and cannot report deployed addresses. IMD's deployer launches through the factory
after this step is accepted. The addresses come from that launch and should be checked against the hashes above.

## Checks run

- `forge build`: passes.
- `forge test --no-match-path "test/fork/*"` with `FOUNDRY_FUZZ_SEED=0xd17e95d2…af0d`: 111 tests pass. These are
  the project's original 105 plus 6 in `test/Launch.t.sol`.
- `test/fork/JudgeFork.t.sol::test_ethereum` against Ethereum mainnet (public RPC, block about 26,386,700):
  passes. It covers a real ask in ETH through the door (610,171 gas), through `Judged` (677,157 gas) and in IMD
  (474,015 gas), on the live Intake, IMD and Uniswap v4 pool.
- The protected `Contracts.protected.t.sol` probe, run with both contracts' init code and the brief's arguments
  on chain 1 in one `create2` batch: passes. The runtimes are present, within EIP-170 and free of forbidden
  opcodes. I could not run `Owners.protected.t.sol` here because its `floor/OwnerChecks.sol` is not on this
  machine. Neither contract has an owner of any kind.
- Live dependencies on chain 1 (`cast`):
  - The Intake and IMD have code, and IMD's `symbol()` is `IMD`.
  - `priceOf(oracle.request@oracle-1, IMD)` returns `5e17`.
  - The PoolManager has code. The ETH/IMD pool (fee 10000, tick spacing 200, no hook) is initialized, with
    slot0 showing an LP fee of 10000.
  - The oracle signer is an EOA, as the oracle-consumer reference lists it.
- `POST https://api.imd.fun/requests/check` with Judge's real question for a sample case on chain 1, panel size
  100, evidence `panel`: `blockers: []`, `limits: {minPanelSize: 5, maxPanelSize: 100}`.
- `src/OracleAttestation.sol` matches the library and consumer in the oracle-consumer `REFERENCE.md`. The
  struct, type string, domain name and version are the same.
- Slither and Mythril were not run: neither is installed on this machine.

## Audit findings on the code as it arrived

1. **[info] `Judged` has no Ethereum entry** (`src/Judged.sol`, `_judge()`). *Reproduces*: on chain 1, `_judge()`
   reverts with "Judged: Judge isn't on this chain", so no inheritor deploys there yet. *Not changed*:
   - The entry needs the deployed `Judge` and `JudgeEthDoor` addresses. They only exist once IMD's deployer
     launches, and guessing them would be a stand-in.
   - `Judged.sol` is not deployed by this launch, so adding the pair later changes neither deployed bytecode.
   - Follow-up after launch: add `if (block.chainid == 1) return (<Judge>, <JudgeEthDoor>);` with
     `door.judge() == judge`, and update the README's Deployments table.
2. **[info] `panelSize` 100 equals the plane's current maximum** (`src/Judge.sol`). *Reproduces as described*: it is
   valid today, since `/requests/check` returned `maxPanelSize: 100` and no blockers, but there is no headroom.
   *Not changed*: it is a trust assumption on the plane, not a defect. The brief fixes 100/51 and forbids setters.
   If IMD lowers the cap, this `Judge` charges for cases that end in `NoAnswer`, and the remedy is a new `Judge`.

## Review

I found nothing critical or high in `Judge`, `JudgeEthDoor` or `Judged`, so no contract code changed.

### `Judge`

- **Access**:
  - `onOracleResult` and `onOracleFailure` take calls only from the Intake, and only for a request asked here
    and still `Pending`.
  - An answer must carry the case's own `questionHash`. That hash names the case id, this contract's address,
    chain 1 and a one-block window.
  - The panel must be at least 100/51 with `agreed >= quorum`, and must arrive within the day.
  - The answer must carry a valid EIP-712 signature in this contract's own domain. OpenZeppelin's
    `SignatureChecker` rejects malleable signatures.
- **Funds**: it pulls exactly `price()` from `msg.sender` and approves exactly that to the Intake, which pulls it.
  It holds nothing between calls.
- **Trust**:
  - The Intake and its writer can end any case as `NoAnswer` through the unsigned failure call, and they decide
    which answer is delivered to which request.
  - A `Yes` also needs the oracle key's signature over the case's own question.
  - A new signer or action version leaves this `Judge` unable to take answers, and its cases end in `NoAnswer`.
    The README already states all of this.
- **Untested edge (low)**: `ask` computes `block.number - WINDOW_DEPTH`, which underflows below block 8. That
  cannot happen on Ethereum.

### `JudgeEthDoor`

- `unlockCallback` takes calls only from the PoolManager, which calls back only whoever called `unlock`. That is
  this contract.
- It holds nothing between calls and refunds last.
- **Low or design**: the swap's price limit is `MIN_SQRT_PRICE + 1`, so the only slippage bound is the ETH
  attached. A sandwich can take the caller up to that amount. The door's docs and the README say to attach
  little. Changing this would change a function's behaviour and signature, which the brief rules out.

### `Judged` (inherited by other people; not deployed here)

- `settle` deletes the open id before running the hook. A `busy` flag blocks re-entering `ask` and `settle` from
  the hooks and from the change refund. Ids come only from this contract's own asks.
- The `(block.number, msg.sender, msg.value)` key stops a multicall or loop from reusing `msg.value` to pay from
  the contract's own balance.
- Change is measured as the balance difference around the door call. No third-party code runs inside that
  window: the pool has no hook, and IMD and the Intake make no callbacks.
- **Low (liveness)**: the same sender with the same `msg.value` cannot ask twice in one block. That is
  intentional and documented.
- **Low (design)**: on Sepolia (no door), an `ask` pays in imdTEST from the inheritor's own balance, and its whole
  budget comes back as change. Anyone who can call the inheritor's asking function spends that balance. This is
  documented in the README.
- **Low (design)**: an inheritor that spends part of `msg.value` before calling the two-argument `ask` pays the
  difference from its own money. The NatSpec and README say to use `ask(question, proof, budget)` for this.
- **Low (future)**: `open` is keyed by id alone. If `_judge()` ever returned a different `Judge` for the same chain,
  ids from the two could collide. The pairs are constants today, so this cannot happen.
- **Info**: covered by audit finding 1. Inheritors cannot deploy on Ethereum until the chain-1 pair is added after
  launch.
