## Sealed Art
Sealed Art is a marketplace for 1/1 NFTs that aims to improve the experience of bidding on NFTs by introducing:
- Gasless bidding
- Private bids
- Vikrey auctions
- Automated bidding bots

The way this will be achieved is through a core contract where:
- Users can deposit funds
- Users can bid on NFTs by signing a message with max amount and sending it to a server
- At the end of the auction server will pick the highest bid, sign it as well, and publish it so auction can be settled on-chain
- Users can withdraw amounts that are not in active bids by getting a signed message from the server
- If server is down, users can withdraw on their own through a 2-step process that lasts 2 days

This delayed withdrawal mechanism prevents bid manipulation where someone could bid up a piece but then withdraw their coins, making the bids impossible to settle. It's expected that users will always withdraw instantly with signed messages, delayed withdrawal is only there in case something terribly wrong happens to server.

## Risks
This introduces a trusted server, which gets to pick the winning bid, this server will be able to:
- Leak private bid amounts
- Pick the winning bid, which when used maliciously could be used to select subpar bids

The server doesn't take custody and it won't be able to rug your ETH or NFTs. Furthermore, server will sign messages attesting to bid reception, so if it ever picks incorrect bids it will be possible to prove cryptographically that the server has misbehaved.

## Sealed bids
A problem with private bids is that they leak max value because users can only bid up to what they have deposited into the contract, to solve that we introduced a new type of hidden funding txs that can be masked as regular ETH transfers between any address and a custom-made address that just looks like a regular address.

## Invariants
- Every time _balances is modified we emit a Transfer event
- Every time money is sent out we reduce someone's balance an equal amount
- Any action on an auction can only happen if the auction is open

## Scripts

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat run scripts/deploy.ts

PRIVATEKEY=xxx npx hardhat run scripts/deploy.ts --network fuji
ETHERSCAN_API_KEY=xxx npx hardhat verify --network fuji contract_address params
```
