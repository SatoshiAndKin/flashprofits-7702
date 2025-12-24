#!/bin/bash
set -e

# Fork mainnet and run the migration script
# Uses vm.prank to simulate execution from USER address

RPC_URL="${ETH_RPC_URL:-https://eth.llamarpc.com}"

echo "Forking mainnet from: $RPC_URL"
echo ""

forge script script/ForkMigrate.s.sol:ForkMigrateScript \
    --fork-url "$RPC_URL" \
    -vvvv
