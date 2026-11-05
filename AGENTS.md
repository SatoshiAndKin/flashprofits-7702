# Contract instructions

- Use the installed Forge, Solidity, and forge-std versions and existing project layout.
  Follow the repository's compiler, optimizer, and dynamic-linking configuration.
- Ask before editing `foundry.toml`; explain each proposed property and its purpose.
- Use named Solidity imports and custom errors instead of revert strings. Prefer
  `if (!condition) revert CustomError();`. Document public/external contracts with NatSpec.
- Keep assertions out of `setUp()`. Cover affected state changes, return values, events,
  access controls, reverts, and protocol interactions. Use fuzz/invariant tests when
  the changed behavior requires properties across inputs or call sequences.
- Validate with `forge build`, `forge fmt --check`, and the affected `forge test` suites.
  Run `forge snapshot --diff` after changes and investigate material gas regressions.
  Check installed `forge lint` support and address relevant high-severity findings.
- For fork configuration and cheatcode ordering, use the `foundry-fork-testing` skill.
  For requested gas optimization, use `forge-gas-golf`. Deployment and live transactions
  require authorization separate from code changes.
