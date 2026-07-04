# Contract verification — HermesRitualLLM

Verification bundle for the deployed contract. The source and these exact
compiler settings reproduce the on-chain bytecode.

| Field | Value |
|-------|-------|
| Address | `0x076d193E55C526ae709c529EA952847eB3eb2441` |
| Chain | Ritual testnet (1979) |
| Contract | `contracts/HermesRitualLLM.sol:HermesRitualLLM` |
| Compiler | `v0.8.20+commit.a1b79de6` |
| Optimizer | enabled, 200 runs |
| viaIR | `true` |
| EVM version | `paris` |
| Metadata bytecodeHash | `ipfs` |

`HermesRitualLLM.standard-input.json` is the Solidity **standard-json input** for
manual submission (explorer "Verify & Publish" → Standard-JSON-Input).

## Status

The verifier endpoint documented by the Ritual deploy skill
(`https://rpc.ritualfoundation.org/api/verify`) is **not reachable publicly** as
of this deployment — GET and POST both return `{"error":"unknown path"}`, and the
explorer host serves only the UI (no Blockscout/etherscan API). Verification
could not be submitted. Once a working verifier URL is known (e.g. from Ritual
Discord / chain-deployment infra), run the one command below.

## Verify via forge (when a working endpoint is available)

```bash
forge verify-contract \
  --chain 1979 \
  --num-of-optimizations 200 \
  --compiler-version 0.8.20 \
  --evm-version paris \
  --via-ir \
  --verifier custom \
  --verifier-url "$RITUAL_VERIFIER_URL" \
  --verifier-api-key unused \
  --skip-is-verified-check \
  --watch \
  0x076d193E55C526ae709c529EA952847eB3eb2441 \
  contracts/HermesRitualLLM.sol:HermesRitualLLM
```

## Verify manually via the explorer UI

1. Open the contract on `https://explorer.ritualfoundation.org` and choose
   "Verify & Publish" → "Solidity (Standard-JSON-Input)".
2. Compiler: `v0.8.20+commit.a1b79de6`.
3. Upload `HermesRitualLLM.standard-input.json`.
4. Contract name: `contracts/HermesRitualLLM.sol:HermesRitualLLM`.
