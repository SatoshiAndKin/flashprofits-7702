# Resupply Targets

IMPORTANT: I wrote these in solidity just as a quick experiment.

TODO: Instead of deploying contracts for each action, use weiroll. compare gas costs to see how many times a transaction needs to happen before deploying is cheaper.

IF weiroll ends up being less efficient than I expect, we can keep the pattern of deploying more this way. But I think weiroll is probably going to be good.

# Other contracts (or maybe weirolls) to write

## Resupply CrvUSD Flash Exit

if we use their exit by repaying with collateral script, it is hard to exit with the exact right amount. the website makes it easy to exit to 100% reusd.

note: exits have to leave at least 1k reusd borrowed

