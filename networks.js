require("dotenv").config();
const privateKeys = [process.env.PRIVATE_KEY];
const HDWalletProvider = require("@truffle/hdwallet-provider");

module.exports = {
  networks: {
    development: {
      protocol: "http",
      host: "localhost",
      port: 8545,
      gas: 5000000,
      gasPrice: 5e9,
      networkId: "*",
    },
    bsc: {
      provider: () =>
        new HDWalletProvider(privateKeys, "https://bsc-dataseed.binance.org"),
      networkId: 56,
      gas: 6000000,
      gasPrice: 20e9,
    },
    bsc_testnet: {
      provider: () =>
        new HDWalletProvider(
          privateKeys,
          "https://data-seed-prebsc-1-s2.binance.org:8545"
        ),
      network_id: 97,
      confirmations: 3,
      // timeoutBlocks: 200,
      gas: 6000000,
      gasPrice: 20e9,
      skipDryRun: true,
      // networkCheckTimeout: 90000,
      // Resolve time out error
      // https://github.com/trufflesuite/truffle/issues/3356#issuecomment-721352724
    },
  },
};
