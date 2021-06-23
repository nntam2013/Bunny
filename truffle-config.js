require("dotenv").config();

const HDWalletProvider = require("@truffle/hdwallet-provider");
const privateKeys = [process.env.PRIVATE_KEY]; // private keys

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
      timeoutBlocks: 200,
      gasPrice: 10e9,
      skipDryRun: true,
      // networkCheckTimeout: 90000,
      // Resolve time out error
      // https://github.com/trufflesuite/truffle/issues/3356#issuecomment-721352724
    },
  },
  mocha: {
    // timeout: 100000
  },

  // Configure your compilers
  compilers: {
    solc: {
      version: "0.6.12", // Fetch exact version from solc-bin (default: truffle's version)
      settings: {
        evmVersion: "istanbul",
        optimizer: {
          enabled: true,
          runs: 200,
        },
      },
    },
  },
  db: {
    enabled: false,
  },
  plugins: ["truffle-contract-size"],
};
