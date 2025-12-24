## Project conventions

### Reverts / errors

- Do not use revert strings.
- Prefer Solidity custom errors.
- Preferred pattern:

```solidity
require(condition, CustomError());
```

Instead of:

```solidity
if (!condition) revert CustomError();
```
