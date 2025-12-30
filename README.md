# flashprofits-foundry-7702

Foundry project for experimenting with **EIP-7702 delegated EOAs**, **flash-loans**, and **transaction batching**.

## Quickstart

### Setup

1. Create a `.env` to match the `env.example`. You'll need some API keys, an RPC, and 

### Scripts

#### Resupply crvUSD Markets

Deposit into a crvUSD market on a forked network:

    ```shell
    MARKET=0xd42535cda82a4569ba7209857446222abd14a82c \
    forge script script/ResupplyCrvUSDFlashEnter.s.sol:ResupplyCrvUSDFlashEnterScript \
        --fork-url "mainnet" \
        --sender "0xYOUR_ADDRESS_HERE" \
    ;
    ```

TODO: This has arguments!

    ```shell
    forge script script/ResupplyCrvUSDMigrate.s.sol:ResupplyCrvUSDMigrateScript \
        --fork-url "mainnet" 
    ```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas snapshots

```shell
forge snapshot
```

### Coverage

```shell
forge coverage --skip script
```

## Contracts

TODO: This is ai slop

### `FlashAccount` (`src/FlashAccount.sol`)

An EIP-7702 delegation target meant to be **etched onto an EOA** (or used via `--auth` delegation) so that the EOA can execute a single call path where `msg.sender == address(this)`.

- `transientExecute(target, data)` is the entrypoint: it sets a transient “implementation” slot to `target`, performs the call, and clears the slot.
- `fallback()` delegates to the transient implementation slot when set; otherwise it returns, making the account behave like an EOA for unknown selectors.
- Includes a transient-slot based reentrancy guard (slot must be empty).

### `ResupplyCrvUSDFlashMigrate` (`src/transients/ResupplyCrvUSDFlashMigrate.sol`)

Delegate-call-only migration logic that:

1. Takes a crvUSD flash loan.
2. Opens a position on a target Resupply market.
3. Repays the source market borrow (by shares).
4. Withdraws collateral directly to the flash lender to repay the flash loan.

Intended to be invoked via `FlashAccount.transientExecute(...)` so it runs in the context of the delegated EOA.

### `OnlyDelegateCall` (`src/abstract/OnlyDelegateCall.sol`)

Small guard used by migration contracts to ensure they are **only executed via `delegatecall`**.

## Scripts

### 0) Start a forked mainnet node

TODO: This is ai slop

```shell
anvil --fork-url "$MAINNET_RPC_URL"
```

In a separate terminal:

```shell
export RPC_URL=http://localhost:8545
export ACCOUNT=<your_eoa_address>
```

### 1) Deploy `FlashAccount`

TODO: This is ai slop

```shell
forge script script/FlashAccount.s.sol:FlashAccountScript \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --broadcast \
  --sig "deploy()"
```

Set the implementation address (from the broadcast output):

```shell
export FLASHACCOUNT_IMPL=<deployed_FlashAccount_address>
```

### 2) Delegate your EOA to `FlashAccount` (EIP-7702)

TODO: This is ai slop

TODO: Ledger won't let us delegate to a custom contract! They only allow like 6 pre-approved ones. And none of them do delegatecall like I want.

Ledger/keystore path (no private keys):

```shell
cast send \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --auth "$FLASHACCOUNT_IMPL" \
  "$ACCOUNT" \
  --value 0
```

Dev-only path (uses Foundry cheatcodes):

```shell
IMPLEMENTATION="$FLASHACCOUNT_IMPL" \
AUTHORITY_PK=<anvil_private_key_as_uint> \
forge script script/FlashAccount.s.sol:FlashAccountScript \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --sig "delegate()"
```

### 3) Deploy `ResupplyCrvUSDFlashMigrate`

TODO: This is ai slop

```shell
forge script script/ResupplyCrvUSDFlashMigrate.s.sol:ResupplyCrvUSDFlashMigrateScript \
  --rpc-url "$RPC_URL" \
  --account <keystore_account_name> \
  # or: --ledger \
  --broadcast \
  --sig "deploy()"
```

Set the migrate implementation address:

```shell
export MIGRATE_IMPL=<deployed_ResupplyCrvUSDFlashMigrate_address>
```

### 4) Execute a migration via flash loan

TODO: This is ai slop

```shell
export SOURCE_MARKET=<resupply_pair_address>
export TARGET_MARKET=<resupply_pair_address>
export AMOUNT_BPS=10000

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

### 5) Print market status

```shell
ACCOUNT="$ACCOUNT" \
SOURCE_MARKET="$SOURCE_MARKET" \
TARGET_MARKET="$TARGET_MARKET" \
forge script script/ResupplyCrvUSDFlashMigrate.s.sol:ResupplyCrvUSDFlashMigrateScript \
  --rpc-url "$RPC_URL" \
  --sig "status()"
```