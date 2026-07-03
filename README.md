# hermes-ritual-bridge

A Solidity bridge that gives a **Hermes AI agent** access to decentralized,
on-chain LLM inference via **Ritual Chain's native LLM precompile (`0x0802`)**.

The agent submits a text prompt to `HermesRitualLLM`; the contract calls the
enshrined LLM precompile; Ritual's TEE-verified executor runs the model
(`zai-org/GLM-4.7-FP8`) off-chain and the result is settled back into the same
transaction (short-running async — **no callback**). The decoded assistant text
is stored and emitted on-chain. Fees are paid in RITUAL through **RitualWallet**.

> This is not a token bridge. "Bridge" here means bridging Hermes → Ritual inference.

## How it works

```
Hermes agent ──ask(executor, prompt)──▶ HermesRitualLLM ──call──▶ 0x0802 (LLM precompile)
                                              │                          │  TEE executor
                                              │                          ▼  runs GLM-4.7-FP8
                                              │◀── settled response (same tx, fulfilled replay)
                                              ▼
                                    store + emit InferenceCompleted(id, hasError, content)
```

## Ritual reference (Chain ID 1979)

| Item | Value |
|------|-------|
| LLM precompile | `0x0000000000000000000000000000000000000802` |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| Model (pinned) | `zai-org/GLM-4.7-FP8` (64K context) |

Interface, ABI, and addresses follow the official
[`ritual-foundation/ritual-dapp-skills`](https://github.com/ritual-foundation/ritual-dapp-skills)
reference (skills: `ritual-dapp-llm`, `ritual-dapp-wallet`, `ritual-dapp-da`).

## Contract API — `HermesRitualLLM`

- `ask(address executor, string prompt) → uint256 id` — JSON-escapes the prompt,
  wraps it as a single user message, and requests inference.
- `askWithMessages(address executor, string messagesJson) → uint256 id` — pass a
  full OpenAI-style messages array (system prompts / multi-turn).
- `inferences(uint256 id)` — stored result: `hasError`, decoded `content`,
  `finishReason`, `errorMessage`, and raw `completionData` for off-chain decode.
- `decodeCompletion(bytes)` — pull assistant text + finish reason from raw bytes.
- **Fees:** `depositFees(lockDuration)`, `depositForAgent(agent, lockDuration)`,
  `feeBalance()`, `withdrawFees(amount, to)`.
- **Admin (owner):** `setTtl`, `setMaxCompletionTokens`, `setTemperature`,
  `transferOwnership`.

## Usage outline

1. **Fund fees.** Deposit RITUAL into RitualWallet before inference. The chain
   escrows a worst-case (~0.31 RITUAL) per in-flight call and refunds the rest.
   Deposit at least ~0.5 RITUAL. *Async fee checks are against the tx signer:* if
   the Hermes EOA calls the precompile path directly, fund that EOA
   (`depositForAgent`), not just the contract.
2. **Pick an executor.** Query
   `TEEServiceRegistry.getServicesByCapability(1, true)` off-chain and pass a
   valid `teeAddress` as `executor`.
3. **Ask.** Call `ask(executor, "your prompt")`. Read the result from the
   `InferenceCompleted` event or `inferences(id)`.

## Layout

```
contracts/HermesRitualLLM.sol    The precompile consumer + fee management
scripts/deploy.ts                Deployment
scripts/request-inference.ts     Discover executor, fund fees, run a prompt
test/HermesRitualLLM.test.ts     Escaping + response-decoder tests
```

## Getting started

```bash
npm install
cp .env.example .env   # set RITUAL_RPC_URL and PRIVATE_KEY
npm run compile
npm test

# Deploy, then add the printed address as CONSUMER_ADDRESS in .env
npm run deploy -- --network ritual

# Fund fees + run an end-to-end inference (set PROMPT to override the default)
npm run request -- --network ritual
```

## Notes & caveats

- **Reasoning model:** GLM-4.7-FP8 emits a hidden `<think>` chain-of-thought, so
  `maxCompletionTokens` is floored at 4096 (smaller caps risk empty replies) and
  `ttl` defaults to 300 blocks.
- **One short-running async call per transaction** — you cannot make two async
  precompile calls in a single transaction (synchronous precompiles are fine).
- **Always check `hasError` before using `completionData`** — the contract does;
  on-chain decode failures fall back to empty `content` with raw bytes preserved.
- **Stateless by default** — conversation history uses an empty DA StorageRef
  (`('','','')`). Wire up GCS/HF/Pinata (see `ritual-dapp-da`) for persistence.

## Author

Erhan ([@erhnysr](https://github.com/erhnysr))

## License

MIT
