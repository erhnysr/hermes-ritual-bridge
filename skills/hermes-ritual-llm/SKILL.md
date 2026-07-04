---
name: hermes-ritual-llm
category: onchain-ai
description: Give Hermes decentralized, on-chain LLM inference by calling the HermesRitualLLM contract, which wraps Ritual Chain's native LLM precompile (0x0802). Deploy or reuse the contract, ask() a prompt, and read the TEE-verified result back from inferences(id).
tags: [ritual, llm, onchain-inference, precompile, tee, web3, hermes]
---

# Hermes ⇄ Ritual on-chain LLM inference

This skill lets Hermes run text inference **on-chain** through Ritual Chain's
enshrined LLM precompile (`0x0802`), executed inside a TEE by a registered
executor and settled back into the same transaction. Use it when you want an
LLM answer that is verifiable and recorded on-chain rather than fetched from a
centralized API.

The `HermesRitualLLM` contract (in this repo, `contracts/HermesRitualLLM.sol`) is
the entry point. You send a prompt to `ask()`; the contract calls the precompile,
decodes the response, and stores it under an incrementing id. There is **no
callback** — the result is available as soon as the transaction is mined.

## When to use this skill

- Hermes needs an LLM answer that is auditable / provable on-chain.
- The user asks for "on-chain inference", "Ritual LLM", "decentralized AI", or
  to record model output on a public ledger.
- Do **not** use this for streaming UX or private/PII data without reading the
  `ritual-dapp-llm` and `ritual-dapp-secrets` references first.

## Fixed facts (do not improvise)

| Item | Value |
|------|-------|
| Chain | Ritual Chain, **Chain ID 1979** |
| RPC | `https://rpc.ritualfoundation.org` (EIP-1559 only — never send legacy tx) |
| LLM precompile | `0x0000000000000000000000000000000000000802` |
| RitualWallet (fees) | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| Model (pinned) | `zai-org/GLM-4.7-FP8` |
| Operator wallet | `0xD3467E00F6d7275C74e60fc7A1E5eD526893B29F` |
| **HermesRitualLLM (deployed)** | `0x076d193E55C526ae709c529EA952847eB3eb2441` (Ritual testnet) |

> Fees are paid in **RITUAL through RitualWallet, not gas**. Get testnet RITUAL
> from `https://faucet.ritualfoundation.org` before running anything.

---

## Step 1 — Get a contract instance

### Option A: reuse an already-deployed instance (preferred)

Set `CONSUMER_ADDRESS` in `.env` to the deployed `HermesRitualLLM` address (the
placeholder in the table above). Confirm it has code:

```bash
cast code <CONSUMER_ADDRESS> --rpc-url https://rpc.ritualfoundation.org
# non-empty (not "0x") => contract is live
```

### Option B: deploy a fresh instance

```bash
# From the repo root, with .env holding RITUAL_RPC_URL + PRIVATE_KEY
npm install
npm run deploy -- --network ritual
# -> prints "HermesRitualLLM deployed to: 0x..."
# Copy that address into .env as CONSUMER_ADDRESS and into this skill's table.
```

---

## Step 2 — Pick a TEE executor (LLM capability)

`ask()` requires a registered executor address. Query the registry for nodes
advertising the LLM capability (`Capability.LLM = 1`) and use a valid one's
`teeAddress`:

```bash
cast call 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F \
  "getServicesByCapability(uint8,bool)(((address,address,uint8,bytes,string,bytes32,uint8),bool,bytes32)[])" \
  1 true --rpc-url https://rpc.ritualfoundation.org
```

Pick an entry where `isValid == true` and read its `teeAddress` (the 2nd address
in the inner `node` tuple). If none are valid, retry later — executors come and
go. The repo's `scripts/request-inference.ts` does this discovery automatically.

---

## Step 3 — Fund fees (once, with headroom)

**Confirmed on testnet:** the LLM fee is charged against the RitualWallet balance
of the **transaction signer (the EOA)**, even though the contract is what calls
`0x0802` — the chain recovers the signer from the original tx. Fund the signer,
not the contract. Worst-case escrow for `GLM-4.7-FP8` is ~0.31 RITUAL per
in-flight call; deposit ≥ 0.4 RITUAL. The lock is monotonic (only extends).

```bash
# Deposit 0.5 RITUAL into the SIGNER's RitualWallet balance, locked 100000 blocks
cast send 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948 "deposit(uint256)" 100000 \
  --value 0.5ether \
  --rpc-url https://rpc.ritualfoundation.org --private-key $PRIVATE_KEY

# Check the signer's fee balance
cast call 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948 \
  "balanceOf(address)(uint256)" <SIGNER_ADDRESS> \
  --rpc-url https://rpc.ritualfoundation.org
```

> A revert with `insufficient wallet balance (user: <EOA>)` means the signer's
> balance is empty — deposit for that exact EOA. From a contract you can also use
> `HermesRitualLLM.depositForAgent(<EOA>, 100000)` (payable), which forwards to
> `RitualWallet.depositFor`.

---

## Step 4 — Ask a prompt

`ask(address executor, string prompt)` JSON-escapes the prompt, wraps it as a
single user message, calls the precompile, and stores the result. Always pass an
explicit gas limit — async precompile calls cannot be gas-estimated.

```bash
cast send <CONSUMER_ADDRESS> \
  "ask(address,string)" <EXECUTOR_ADDRESS> "In one sentence, what is Ritual Chain?" \
  --gas-limit 5000000 \
  --rpc-url https://rpc.ritualfoundation.org --private-key $PRIVATE_KEY
```

Or use the repo script end-to-end (auto-discovers executor + funds fees):

```bash
CONSUMER_ADDRESS=<addr> PROMPT="In one sentence, what is Ritual Chain?" \
  npm run request -- --network ritual
```

For system prompts / multi-turn, use `askWithMessages(executor, messagesJson)`
with a full OpenAI-style array, e.g. `[{"role":"system","content":"..."},{"role":"user","content":"..."}]`.

---

## Step 5 — Read the result back

Each `ask()` stores a record. The id is `inferenceCount() - 1` for your latest
call (or read it from the `InferenceCompleted(id, requester, hasError, content, errorMessage)`
event log on the tx receipt).

```bash
# Latest id
cast call <CONSUMER_ADDRESS> "inferenceCount()(uint256)" \
  --rpc-url https://rpc.ritualfoundation.org
# -> N ; your record id is N-1

# Read the stored inference (id = N-1)
cast call <CONSUMER_ADDRESS> \
  "inferences(uint256)(address,bool,bool,string,string,string,bytes)" <ID> \
  --rpc-url https://rpc.ritualfoundation.org
```

The returned tuple is:

| Field | Meaning |
|-------|---------|
| `requester` (address) | who called `ask` |
| `completed` (bool) | record was written |
| `hasError` (bool) | **check this first** — true = inference failed |
| `content` (string) | decoded assistant text (the answer) |
| `finishReason` (string) | `stop` = complete; `length` = hit the token cap |
| `errorMessage` (string) | freeform error when `hasError` |
| `completionData` (bytes) | raw ABI CompletionData for off-chain decode |

**Interpretation rules for Hermes:**
- If `hasError == true`, surface `errorMessage`; do not use `content`.
- If `content` is empty and `finishReason == "length"`, the reasoning model ran
  out of output budget — retry after `setMaxCompletionTokens` (≥ 4096; higher for
  long answers), owner-only.
- If `content` is empty but `hasError == false` with `completionData` present,
  on-chain decode was skipped/failed — decode `completionData` off-chain via
  `decodeCompletion(bytes)` (a `pure` helper on the contract) or the TS decoder
  in `scripts/`.

---

## Gotchas (Ritual-specific — these violate normal EVM assumptions)

- **No callback.** LLM (`0x0802`) is short-running async; the result settles into
  the same transaction (fulfilled replay). Read it right after the tx is mined —
  do not wait for a delivery callback.
- **One short-running async call per transaction.** You cannot issue two async
  precompile calls in a single tx.
- **EIP-1559 only.** Legacy (type-0) transactions are rejected. `cast`/viem send
  type-2 by default — don't pass `--legacy`.
- **Reasoning model.** `GLM-4.7-FP8` emits a hidden `<think>` block; the contract
  floors `maxCompletionTokens` at 4096 and `ttl` at 300 blocks for this reason.
- **Fees ≠ gas.** A call with plenty of ETH-for-gas still fails if the RitualWallet
  fee balance (Step 3) is empty.

## References

Contract, ABI, addresses, and fee semantics follow the official
`ritual-foundation/ritual-dapp-skills` reference: `ritual-dapp-llm`,
`ritual-dapp-wallet`, `ritual-dapp-deploy`, `ritual-dapp-da`.
