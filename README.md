# flashprofits-foundry-7702

Foundry project for experimenting with **EIP-7702 delegated EOAs**, **flash-loans**, and **transaction batching**.

Unlike standard proxy contracts, the FlashAccount is only active while the EOA is sending a transaction. This should reduce any attack surface from a bug in a target contract.

## Quickstart

### Setup

1. Install [foundry](https://getfoundry.sh/)
2. Create a `.env` to match the `env.example` (You'll need some API keys and an RPC).

TODO: docs for setting up an account for use with `cast send` and `forge script`

### Deploy `FlashAccount`

On a forked network:

```shell
forge script script/FlashAccount.s.sol \
  --fork-url "mainnet" \
  --broadcast \
  --verify \
  --sig "deploy()" \
;
```

For mainnet, replace `--fork-url` with `--rpc-url`. And add either `--account` or `--ledger`

NOTE: If the script is already deployed, this won't do anything.

### Delegate your EOA to `FlashAccount` using EIP-7702

TODO! Ledger won't let us delegate to a custom contract! They only allow like 6 pre-approved ones. And none of them do delegatecall like I want. 

Forge scripts require access to the private key to sign authorizations. We can instead use `cast` with a keystore account:

```shell
cast send \
  --rpc-url "mainnet" \
  --account <keystore_account_name> \
  --auth "$FLASHACCOUNT_IMPL" \
  "$ACCOUNT"
```

Dev-only path (uses Foundry cheatcodes):

```shell
forge script script/FlashAccount.s.sol \
  --fork-url "mainnet" \
  --broadcast \
  --sig "delegate()"
```

### Scripts

#### Resupply Markets

NOTE: Currently, these contracts only work with the crvUSD markets. But they aren't hard to modify to support the frxUSD markets.

Resupply has a lot of `CURVELEND` pairs: <https://raw.githubusercontent.com/resupplyfi/resupply/refs/heads/main/deployment/contracts.json>

On a forked network, make a leveraged deposit into a crvUSD market:

  ```shell
  MARKET=0xd42535cda82a4569ba7209857446222abd14a82c \
  forge script script/ResupplyCrvUSDFlashEnter.s.sol:ResupplyCrvUSDFlashEnterScript \
      --fork-url "mainnet" \
      --sender "0xYOUR_ADDRESS_HERE" \
  ;
  ```

On a forked network, migrate 100% of funds from one crvUSD market to another:

  ```shell
  SOURCE_MARKET=0xSOURCE_MARKET_ADDR \
  TARGET_MARKET=0xTARGET_MARKET_ADDR \ 
  AMOUNT_BPS=10000 \
  forge script script/ResupplyCrvUSDMigrate.s.sol:ResupplyCrvUSDMigrateScript \
      --fork-url "mainnet" 
      --sender "0xYOUR_ADDRESS_HERE" \
  ;
  ```

## Development

### Save new interfaces

Create the output directory:

```shell
mkdir -p src/interfaces/project/
```

Save an interface to a file so that one of our contracts can import it:

```shell
cast interface --chain mainnet 0xSOME_ADDRESS -o src/interfaces/project/SomeInterface.sol
```

### Lint

Check the code against forge's coding standards:

```shell
forge lint
```

### Format

Run the code formatter:

```shell
forge fmt
```

### Build

Building usually happens automatically as needed, but can be done manually:

```shell
forge build
```

### Test

Run the test suite:

```shell
forge test
```

### Gas snapshots

Tun the test suite with gas accounting:

```shell
forge snapshot
```

It's also often useful to check the diff without changing the snapshot file:

```shell
forge snapshot --diff
```

### Coverage

Code coverage is important for ensuring the tests actually cover everything important.

```shell
forge coverage --skip script
```

We skip scripts because they only compile with `via_ir=true`, but ir can interfere with coverage.
