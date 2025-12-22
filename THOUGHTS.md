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