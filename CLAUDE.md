## Project conventions

### Reverts / errors

- Do not use revert strings.
- Prefer Solidity custom errors.
- Preferred (lower-gas) pattern:

```solidity
if (!condition) revert CustomError();
```
