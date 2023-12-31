## Sealed Art v2
Modifications introduced:
- Gasless minting
- Modular system to make new additions easier

## Invariants
- Every time _balances is modified we emit a Transfer event
- Every time money is sent out we reduce someone's balance an equal amount
- Any action on an auction can only happen if the auction is open

## Scripts

```shell
npx hardhat help
npm t
REPORT_GAS=true npm t
npx hardhat node
npx hardhat run scripts/deploy.ts

PRIVATEKEY=xxx npx hardhat run scripts/deploy.ts --network fuji
ETHERSCAN_API_KEY=xxx npx hardhat verify --network fuji contract_address params
```
