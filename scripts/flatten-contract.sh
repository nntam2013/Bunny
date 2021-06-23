#! /bin/bash
if [ ! $1 ]; then echo "Please input contract name"; exit 1; fi
if [ -e "flatten-contracts" ]; then rm -rf "flatten-contracts"; fi
mkdir "flatten-contracts";
mkdir "flatten-contracts/bep";
touch "flatten-contracts/$1.sol";

npx truffle-flattener "./contracts/$1.sol" > "./flatten-contracts/$1.sol"