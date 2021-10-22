const Auction = artifacts.require("NFTAuction");
const library  = artifacts.require("IterableOrderedOrderSet")

module.exports = async function (deployer) {
  await deployer.deploy(library);
  await deployer.link(library, Auction);
  await deployer.deploy(Auction);
};
