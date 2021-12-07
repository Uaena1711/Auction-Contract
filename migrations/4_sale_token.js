const EvryToken= artifacts.require("EvryToken");

const myAddress = process.env.EVRYNET_OPERATOR;
module.exports = async function (deployer) {


  await deployer.deploy(EvryToken, myAddress);
  
};
