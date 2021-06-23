const BunnyMinterV2 = artifacts.require("BunnyMinterV2");

const { deployProxy } = require("@openzeppelin/truffle-upgrades");

module.exports = async function(deployer) {
  await deployProxy(BunnyMinterV2, [], {
    deployer,
    initializer: "initialize",
  });
};
