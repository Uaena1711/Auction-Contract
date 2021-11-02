# Auction-Contract

A Project use block chain technology to create website which everyone can join, bid NFT Token

# Run project

1. Install package
  - `npm i`
  - `cp .env.example .env` to create enviroment file.
  - Enter your private key metamask, your address, network RPC

2. Compile
  - Install truffle: `npm install -g truffle`
  - `truffle compile`

3. Deploy to Block chain
  - Chose network you want deploy at `truffle-config.js`
  - Run: `truffle migrate --reset --network <Your network config>` 
