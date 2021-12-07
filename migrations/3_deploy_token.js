const MyERC721 = artifacts.require("MyERC721");

module.exports = async function (deployer) {

  await deployer.deploy(MyERC721);

  
};
