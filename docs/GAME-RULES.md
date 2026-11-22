# TicTacBase – game rules

- **Stake**: both players put in the same stake, chosen with a slider from **$0.10 to $5.00** in $0.10 steps (paid in ETH at the current Chainlink price).
- **Move fee**: every X or O you place costs a small fee (default **$0.01**). Computer moves are free.
- **Timer**: **10 seconds** per move (+10 s for the very first move). If time runs out, anyone may call `forceMove` and the contract places a **random** mark for the late player.
- **Win**: three in a row → the winner receives **both stakes** automatically.
- **Draw**: both stakes are refunded.
- **Cancel**: a game nobody joined yet can be cancelled by its creator for a full refund.
- **Vs computer**: the house bank matches your stake. The computer always takes a winning move but sometimes misses a block (default 25 %), so it can be beaten.
- **Practice**: free games vs the computer in the browser, no wallet needed.
