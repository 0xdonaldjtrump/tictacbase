# TicTacBase — Tic-Tac-Toe on Base Network 🎮 ❌⭕

**On-chain Tic-Tac-Toe (noughts and crosses) game on Base network** with real stakes. Play another player or the computer. Every move is a transaction on Base L2.

👉 **Play now: https://0xdonaldjtrump.github.io/tictacbase/**

## How it works
- 🎚️ **Pick your stake with a slider: $0.10 – $5.00** (steps of $0.10). Both players put in the same stake.
- ❌⭕ **Every X or O costs a small move fee** ($0.01 by default).
- ⏱️ **10 seconds per move.** Miss it and the computer places a random mark for you.
- 🏆 **Winner takes the whole pot.** Draw = both stakes refunded.
- 🤖 **Play vs computer** — the house bank matches your stake; the computer answers instantly (it can be beaten!).
- 🆓 **Free practice mode** vs the computer, no wallet needed.
- ⚡ **No wallet pop-ups during the game** — a small in-browser game wallet pays move fees and gas. Stakes and winnings always go to your main wallet.
- 🔗 Quick match by stake, open games lobby, invite link, stats (wins / losses / draws), admin panel.
- Works with MetaMask, Coinbase Wallet and any EVM wallet on Base. Prices in USD, paid in ETH (Chainlink ETH/USD oracle).

## Files
- `index.html` — the whole dApp (static, GitHub Pages, ethers.js v6)
- `TicTacBase.sol` — Solidity smart contract (0.8.24, optimizer 200 runs, EVM paris)

> Computer moves use `block.prevrandao` for randomness — fine for a casual game. Play responsibly.

**Keywords:** tic tac toe base, base network game, onchain game, web3 game, crypto game, blockchain game, Base L2 dApp, play to earn, PvP game, noughts and crosses, kółko i krzyżyk, gra na Base.
