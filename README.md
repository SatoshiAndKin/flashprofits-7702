# flashprofits-foundry-7702

Foundry project for experimenting with **EIP-7702 delegated EOAs**, **flash-loans**, and **transaction batching**.


## Contracts

### Flash Account

Similar to a standard upgradable proxy, this contract allows assigning your address to have pretty much any smart contract implementation logic.

Unlike standard proxy contracts, the "FlashAccount"'s main contract logic is only active while the EOA is sending a transaction. This should reduce any attack surface from a bug in a target contract.

### Targets

"Targets" are the primary logic for your Flash Account. They might batch multiple hard coded actions, or they might be highly modular and delegate to other contracts.

WARNING: Like any 7702 delegation, a target can transfer every one of your tokens out in a single transaction! They are very dangerous and must be used carefully!

Good examples:

- Flash Borrower: ERC3156FlashBorrower. Combine this with [Weiroll](https://weiroll.github.io/weiroll.js/) and you can do anything without deploying any extra contracts
- Batching: NonFungibleBreadsticksTarget

Deprecated examples (they may work, but they follow old designs):

- Resupply crvUSD Flash Enter: Use a flash loan and redemptions instead of exchanging to enter a leveraged resupply position.
- Resupply crvUSD Flash Migrate: Use a flash loan to move your leveraged position from one pair to another.
- Resupply crvUSD Flash Optimize: AI Slop contract to find the optimal calls for migrating and leveraging

For security, targets pretty much always require that `msg.sender == address(this)`.

### Flash Loan Targets

"Flash Loan Targets" work with the "Flash Borrower" targets to fill in the logic of their `onFlashLoan` callbacks. The Flash Borrower will receive a bunch of tokens and then delegate call to any contract and function that you want on the "flash loan target".

Depending on your lender, you may need to repay the flash loan with different "modes":
- `RepayMode.Approve`: Some lenders follow the 3156 spec and require setting approvals and they will pull the tokens.
- `RepayMode.Transfer`: Some lenders (like crvUSD) don't fully follow the 3156 flash borrower spec and require you to transfer the tokens yourself. This moduleFor them, its simplest to transfer the repayment from `address(this)` at the very end with.
- `RepayMode.Noop`: sometimes your previous it is most gas efficient to have one of your trades send tokens directly to the lender and then set this mode. This is common if you already have approvals configured, or if a trade in your contract already repayed the lender.

### Poll Targets

"Poll targets" were an experiment with checking for opportunities and then returning transaction calldata. 

TODO: write a script that queries all my poll targets and sends transactions for any that are ready for sending.

TODO: document how to use state overrides. generally, poll targets don't need to be deployed on-chain (unless you want them publically accessible, but doing that securely is "very hard")

TODO: actually. i don't think we want this pattern at all anymore. the polling should be part of flashprofits-rs.

## Quickstart

### Setup

1. Install [foundry](https://getfoundry.sh/)
2. Create a `.env` to match the `env.example` (You'll need some API keys and an RPC).
3. TODO: docs for setting up an account for use with `cast send` and `forge script`

### Deploy `FlashAccount`

On a forked network:

```shell
forge script script/FlashAccount.s.sol --fork-url "mainnet"
```

For mainnet, replace `--fork-url mainnet` with `--broadcast --verify --rpc-url mainnet`. And add either `--account` or `--ledger`

NOTE: If the script is already deployed, this won't do anything.

### Delegate your EOA to `FlashAccount` using EIP-7702

NOTE! Ledger won't let us delegate to a custom contract! They only allow like 6 pre-approved ones. And none of them do delegatecall like I want. 

Forge scripts require access to the private key to sign authorizations. We can instead use `cast` with a keystore account.

1. Check the `deployments.toml` for the address of the `flash_account`

2. Then run this command:

```shell
cast send \
  --rpc-url "mainnet" \
  --account <keystore_account_name> \
  --auth "$FLASH_ACCOUNT_ADDRESS" \
  "$ACCOUNT_ADDRESS" \
;
```

TODO: should we instead use `cast wallet sign-auth --self-broadcast`? I think that doesn't broadcast.

Dev-only path (uses Foundry cheatcodes):

```shell
forge script script/FlashAccount.s.sol \
  --fork-url "mainnet" \
  --sig "delegate()" \
;
```

### Scripts

#### Resupply Markets

NOTE: Currently, these contracts only work with the crvUSD markets. But they aren't hard to modify to support the frxUSD markets.

Resupply has a lot of `CURVELEND` pairs: <https://raw.githubusercontent.com/resupplyfi/resupply/refs/heads/main/deployment/contracts.json>

On a forked network, make a leveraged deposit into a crvUSD market:

```shell
MARKET=0xd42535cda82a4569ba7209857446222abd14a82c \
forge script script/ResupplyCrvUSDFlashEnter.s.sol \
    --fork-url "mainnet" \
    --sender "0xYOUR_ADDRESS_HERE" \
;
```

On a forked network, migrate 100% of funds from one crvUSD market to another:

```shell
SOURCE_MARKET=0xSOURCE_MARKET_ADDR \
TARGET_MARKET=0xTARGET_MARKET_ADDR \ 
MIGRATE_BORROW_BPS=10000 \
MIGRATE_COLLATERAL_BPS=10000 \
forge script script/ResupplyCrvUSDMigrate.s.sol \
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
cast interface --chain mainnet 0xSOME_ADDRESS -o src/interfaces/project/ISomeInterface.sol
```

NOTE: You'll probably want to rename the interface to IProjectContract

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
