const Auction = artifacts.require("NFTAuction");
const library  = artifacts.require("IterableOrderedOrderSet");
const Proxy = artifacts.require("SampleProxy");

module.exports = async function (deployer) {
  await deployer.deploy(library);
  await deployer.link(library, Auction);
  await deployer.deploy(Auction);

  const auctionAddress = await Auction.deployed();

  

  await deployer.deploy(Proxy, auctionAddress.address);
};
