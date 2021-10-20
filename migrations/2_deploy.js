const Auction = artifacts.require("NFTAuction");

module.exports = function (deployer) {
  deployer.deploy(Auction);
};
