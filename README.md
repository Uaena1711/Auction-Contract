# Auction-Contract

A Project use block chain technology to create website which everyone can join, bid NFT Token

# Run project

1. Install package
  - `npm i @truffle/hdwallet-provider`
  - `cp truffle-config.example.js truffle-config.js`
  - Enter your private key metamask 

2. Compile
  - Install truffle: `npm install -g truffle`
  - `truffle compile`

3. Deploy to Block chain
  - Chose network you want deploy at `truffle-config.js`
  - Run: `truffle migrate --reset --network <Your network config>` 
