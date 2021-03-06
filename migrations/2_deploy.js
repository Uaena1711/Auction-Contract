const Auction = artifacts.require("NFTAuction");
const library  = artifacts.require("IterableOrderedOrderSet");
const Proxy = artifacts.require("SampleProxy");

module.exports = async function (deployer) {

  await deployer.deploy(library);
  await deployer.link(library, Auction);
  await deployer.deploy(Auction);

  const auction = await Auction.deployed();
  await auction.initialize();

  /**
    * keccak256(initialize()) = 0x8129fc1c
    * @dev run initialize() function one time when deploy proxy contract
  */
  await deployer.deploy(Proxy, auction.address, 0x8129fc1c);
};
