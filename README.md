## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## EIP-7702 + forked mainnet examples

### 0) Start a forked mainnet node

```shell
anvil --fork-url "$MAINNET_RPC_URL"
```

In a separate terminal:

```shell
export RPC_URL=http://localhost:8545
export ACCOUNT=<your_eoa_address>
```

### 1) MySmartAccount.deploy

```shell
forge script script/MySmartAccount.s.sol:MySmartAccountScript \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --broadcast \
  --sig "deploy()"
```

Set the implementation address (from the broadcast output):

```shell
export MYSMARTACCOUNT_IMPL=<deployed_MySmartAccount_address>
```

### 2) MySmartAccount.delegate (EIP-7702 delegation)

Option A (ledger/keystore signer, no private keys in env):

```shell
cast send \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --auth "$MYSMARTACCOUNT_IMPL" \
  "$ACCOUNT" \
  --value 0
```

Option B (dev-only, uses Foundry cheatcodes `signDelegation` + `attachDelegation`):

```shell
IMPLEMENTATION="$MYSMARTACCOUNT_IMPL" \
AUTHORITY_PK=<anvil_private_key_as_uint> \
forge script script/MySmartAccount.s.sol:MySmartAccountScript \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --sig "delegate()"
```

### 3) ResupplyCrvUSDFlashMigrate.deploy

```shell
forge script script/ResupplyCrvUSDFlashMigrate.s.sol:ResupplyCrvUSDFlashMigrateScript \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --broadcast \
  --sig "deploy()"
```

Set the migrate implementation address (from the broadcast output):

```shell
export MIGRATE_IMPL=<deployed_ResupplyCrvUSDFlashMigrate_address>
```

### 4) ResupplyCrvUSDFlashMigrate.flashLoan

Set the markets and amount:

```shell
export SOURCE_MARKET=<resupply_pair_address>
export TARGET_MARKET=<resupply_pair_address>
export AMOUNT_BPS=10000
```

Then run:

```shell
ACCOUNT="$ACCOUNT" \
MIGRATE_IMPL="$MIGRATE_IMPL" \
SOURCE_MARKET="$SOURCE_MARKET" \
TARGET_MARKET="$TARGET_MARKET" \
AMOUNT_BPS="$AMOUNT_BPS" \
forge script script/ResupplyCrvUSDFlashMigrate.s.sol:ResupplyCrvUSDFlashMigrateScript \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --broadcast \
  --sig "flashLoan()"
```

### 5) ResupplyCrvUSDFlashMigrate.status

```shell
ACCOUNT="$ACCOUNT" \
SOURCE_MARKET="$SOURCE_MARKET" \
TARGET_MARKET="$TARGET_MARKET" \
forge script script/ResupplyCrvUSDFlashMigrate.s.sol:ResupplyCrvUSDFlashMigrateScript \
  --rpc-url "$RPC_URL" \
  --sig "status()"
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## Development

### Interfaces: 

$ cast interface --chain base "$ADDRESS" --output "src/interface/ISomething.sol"

Then probably add an "I" to the start of the contract name