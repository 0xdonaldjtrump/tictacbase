# Levels, XP and leaderboard

All stats live in the contract (`stats(address)` / `getPlayer(address)` / `getLeaderboard(offset, limit)`).

| Result | XP | Leaderboard points |
|---|---|---|
| Win | +30 | +3 |
| Draw | +15 | +1 |
| Loss | +5 | 0 |

Level *n* needs `25 · n · (n − 1)` XP: level 2 = 50 XP, level 3 = 150, level 4 = 300, level 5 = 500 …
Every level-up emits `LevelUp(player, level, xp)`.

Titles: Rookie → Beginner → Player → Skilled → Pro → Expert → Master → Grandmaster → Champion → Legend.
