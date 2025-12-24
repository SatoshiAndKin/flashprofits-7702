# Random Thoughts while writing this

honestly i don't love erc165. its a pain to make sure contracts that do multiple things support it

i also don't really love the 1155 or 721 receiver standards. but whatever. we don't have a choice if we want to interact with them

// use this contract as the implementation contract for an EIP7702Proxy or directly as a 7702 delegation
// we could use 7821 for broad wallet compatability, but i don't really like their enum since it can't do delegatecall
// i don't want 4337 and paymasters and all that. thats way more surface area than i want to deal with securing.
// Number 1 priority is minimizing attack surface area.

// i've tried a lot of iterations of this. i haven't loved any of them.
// 7821 for broad wallet compatability. but i don't really want it. it doesn't seem to do
// so i think that leaves coinbase's 7702 proxy contract as a better option.
// but we don't need that complexity. i'm sure others will have opinions on it. lets just get the core logic working first. copy/pasting when making new ones is fine for now
/*

I can't decide if we should delegate to a special purpose 7702 implementation for ease of use.
or if we should make this more generic and have the user delegate to a flash loan implementation of their choosing.

I want minimal attack surface. these contracts could easily take all my money. here be dragons.


*/

===

a lot of my designs in the past have saved the fallback address into some storage. but that is like leaving a firewall port open with only partially trusted software. lets instead only have our contract callable for the duration of the transaction. and not allow re-entrancy. that should protect us from a lot of known vulnerabilities

===

i keep wanting to do infinite approvals, but we shouldn't do that. its too risky!

===

wait. i dont need to put the key onto the yubikey. on an offline computer, i can do `cast mktx --mnemonic ... --mnemonic-index ... --mnemonic-passphrase ... --mnemonic-derivation-path ...`

because i think `cast send --ledger ...` will reject our custom delegation address. they only accept a whitlist of 6 and none of them worked like i wanted.

===

i'm confused by https://getfoundry.sh/reference/cheatcodes/sign-delegation/

it creates a simple delegation contract that doesn't have any auth on it. does 7702 require permitting specific users to call the function? i'm lost a bit. it might just be a simplified example that isn't secure in production. but that seems like a bad example then. how do we do it securely?!
