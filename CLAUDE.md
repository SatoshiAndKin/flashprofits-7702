## Project conventions

### Corrections

When I correct you on how to do something, take succinct notes somewhere about the right way to do things so you don't compact and forget.

### Reverts / errors

- Do not use revert strings.
- Prefer Solidity custom errors.
- Preferred (lower-gas) pattern:

```solidity
if (!condition) revert CustomError();
```
