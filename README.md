# hermes-ritual-bridge

Cross-chain bridge smart contracts (Hermes ↔ Ritual), built with Hardhat + TypeScript.

## Layout

```
contracts/   Solidity sources
scripts/     Deployment / operational scripts
test/        Hardhat (chai/ethers) tests
```

## Getting started

```bash
npm install
cp .env.example .env   # fill in RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY
npm run compile
npm test
```

## Deploy

```bash
npm run deploy -- --network testnet
```

## License

MIT
