# TicTacBase contract reference

## Players
`createGame(stakeCents, session, nick)` · `joinGame(id, session, nick)` · `playComputer(stakeCents, session, nick)` ·
`move(id, cell)` · `forceMove(id)` · `cancelGame(id)` · `setNick(nick)` · `withdraw()`

`session` is an optional in-browser "game wallet" allowed to move for you (no wallet pop-ups during the game).
Stakes and winnings always go to the main wallet.

## Reads
`getGame(id)` · `getGameNow(id)` · `getOpenGames(offset, limit)` · `getPlayerGames(player, limit)` · `getPlayer(player)` ·
`getLeaderboard(offset, limit)` · `playersCount()` · `info()` · `computerInfo()` · `stakeWeiFor(cents)` · `moveFeeWei()`

## Admin
`setMoveFee` · `setStakeLimits` · `setTimeouts` · `setComputer(enabled, mistakePct)` · `fundHouse()` · `withdrawHouse(amount)` ·
`setPaused` · `setPriceFeed` · `setFallbackWeiPerUsd` · `transferOwnership` · `sweepExtra`
