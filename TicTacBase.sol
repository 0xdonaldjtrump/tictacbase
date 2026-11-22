// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    TicTacBase — on-chain Tic-Tac-Toe on Base with real stakes.

    - Two players put in the same stake: $0.10, $0.20 ... up to $5.00 (paid in ETH, priced via Chainlink ETH/USD).
    - Every X or O placed by a player costs a small move fee (default $0.01) that goes to the owner.
    - Each player has 10 seconds per move. When time runs out anyone can call forceMove()
      and the contract places a random mark for the late player (no fee for computer moves).
    - Winner takes both stakes. Draw = both stakes refunded.
    - Players may register a "session" address (a small in-browser game wallet) that is allowed to
      make moves for them, so moves don't need a wallet popup. Stakes and winnings always go to
      the main wallet, never to the session address.

    - Play vs the computer: the house bank (funded by the owner) matches your stake and the computer
      answers instantly in the same transaction. It always takes a win, but sometimes misses a block,
      so it can be beaten. Win = 2x stake from the house, loss = your stake goes to the house bank.

    Randomness for computer moves uses block.prevrandao — fine for a casual game, not for high stakes.
*/

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract TicTacBase {
    // status
    uint8 public constant OPEN = 1;
    uint8 public constant PLAYING = 2;
    uint8 public constant X_WON = 3;
    uint8 public constant O_WON = 4;
    uint8 public constant DRAW = 5;
    uint8 public constant CANCELLED = 6;

    struct Game {
        address playerX;
        address playerO;
        address sessionX;
        address sessionO;
        uint256 stakeWei;    // per player
        uint32 stakeCents;   // per player, in USD cents
        uint8 status;
        uint8 turn;          // 1 = X, 2 = O
        uint8 moves;
        uint8 winLine;       // 0..7, 255 = none
        uint32 board;        // 2 bits per cell: 0 empty, 1 X, 2 O
        uint16 forcedMask;   // bit i set = cell i was placed by the computer
        uint64 created;
        uint64 lastMove;     // timestamp the current turn started
        uint64 deadline;     // timestamp after which forceMove() is allowed
        bool vsComputer;     // O is the computer (house bank)
    }

    struct Stats {
        uint32 wins;
        uint32 losses;
        uint32 draws;
        uint256 wonWei;
    }

    // ---------- config ----------
    address public owner;
    AggregatorV3Interface public priceFeed;
    uint256 public moveFeeMicroUsd = 10_000;  // $0.01 per move
    uint32 public minStakeCents = 10;          // $0.10
    uint32 public maxStakeCents = 500;         // $5.00
    uint32 public stakeStepCents = 10;         // $0.10 steps
    uint64 public moveTimeout = 10;            // seconds per move
    uint64 public firstMoveGrace = 10;         // extra seconds for the very first move
    uint256 public fallbackWeiPerUsd = 333333333333333; // used if oracle is down (ETH = $3000)
    uint256 public maxPriceAge = 6 hours;
    bool public useFixedPrice;
    bool public paused;
    bool public computerEnabled = true;
    uint8 public computerMistakePct = 25;      // chance the computer misses a needed block
    uint256 public houseBank;                  // ETH the house can stake against players

    // ---------- storage ----------
    uint256 public gameCount;
    mapping(uint256 => Game) private games;
    uint256[] private openIds;
    mapping(uint256 => uint256) private openIndex; // id -> index+1
    mapping(address => uint256[]) private gamesOf;
    mapping(address => Stats) public stats;
    mapping(address => uint256) public pendingWithdrawals;

    uint256 public escrowWei;
    uint256 public totalPendingWei;
    uint256 public totalFeesMicroUsd;
    uint256 public totalVolumeWei;
    uint256 public finishedGames;

    bool private locked;

    // ---------- events ----------
    event GameCreated(uint256 indexed id, address indexed playerX, uint32 stakeCents, uint256 stakeWei);
    event GameJoined(uint256 indexed id, address indexed playerO, uint8 firstTurn);
    event Moved(uint256 indexed id, uint8 side, uint8 cell, bool forced);
    event GameFinished(uint256 indexed id, uint8 status, address winner, uint256 payout);
    event GameCancelled(uint256 indexed id);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event HouseFunded(address indexed from, uint256 amount, uint256 bank);
    event HouseWithdrawn(uint256 amount, uint256 bank);

    // ---------- errors ----------
    error NotOwner();
    error Paused();
    error BadStake();
    error FeeTooLow(uint256 required, uint256 sent);
    error NotOpen();
    error NotPlaying();
    error OwnGame();
    error NotYourTurn();
    error BadCell();
    error TooLate();
    error NotYet();
    error NotCreator();
    error Reentrancy();
    error NothingToWithdraw();
    error TransferFailed();
    error HouseTooSmall();
    error ComputerOff();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        owner = msg.sender;
        priceFeed = AggregatorV3Interface(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70); // Chainlink ETH/USD, Base mainnet
    }

    // =====================================================================
    //                              PRICING
    // =====================================================================

    function weiPerUsd() public view returns (uint256) {
        if (useFixedPrice || address(priceFeed).code.length == 0) return fallbackWeiPerUsd;
        try priceFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) {
                return fallbackWeiPerUsd;
            }
            return (1e18 * 1e8) / uint256(answer); // feed has 8 decimals
        } catch {
            return fallbackWeiPerUsd;
        }
    }

    function quoteMicroUsd(uint256 microUsd) public view returns (uint256) {
        return (weiPerUsd() * microUsd) / 1_000_000;
    }

    function stakeWeiFor(uint32 stakeCents) public view returns (uint256) {
        return quoteMicroUsd(uint256(stakeCents) * 10_000);
    }

    function moveFeeWei() public view returns (uint256) {
        return quoteMicroUsd(moveFeeMicroUsd);
    }

    function validStake(uint32 stakeCents) public view returns (bool) {
        return stakeCents >= minStakeCents && stakeCents <= maxStakeCents && stakeCents % stakeStepCents == 0;
    }

    // =====================================================================
    //                              LOBBY
    // =====================================================================

    /// @notice Create a game with a stake. Anything sent above the stake is forwarded to `session`
    ///         (your in-browser game wallet that pays move fees), or refunded if session is zero.
    function createGame(uint32 stakeCents, address session) external payable nonReentrant returns (uint256 id) {
        if (paused) revert Paused();
        if (!validStake(stakeCents)) revert BadStake();
        uint256 stake = stakeWeiFor(stakeCents);
        if (msg.value < stake) revert FeeTooLow(stake, msg.value);

        id = ++gameCount;
        Game storage g = games[id];
        g.playerX = msg.sender;
        g.sessionX = session;
        g.stakeWei = stake;
        g.stakeCents = stakeCents;
        g.status = OPEN;
        g.winLine = 255;
        g.created = uint64(block.timestamp);

        openIds.push(id);
        openIndex[id] = openIds.length;
        gamesOf[msg.sender].push(id);
        escrowWei += stake;

        emit GameCreated(id, msg.sender, stakeCents, stake);
        _sendExtra(msg.value - stake, session);
    }

    /// @notice Join an open game by paying the same stake. The first turn is chosen at random.
    function joinGame(uint256 id, address session) external payable nonReentrant {
        if (paused) revert Paused();
        Game storage g = games[id];
        if (g.status != OPEN) revert NotOpen();
        if (msg.sender == g.playerX) revert OwnGame();
        uint256 stake = g.stakeWei;
        if (msg.value < stake) revert FeeTooLow(stake, msg.value);

        g.playerO = msg.sender;
        g.sessionO = session;
        g.status = PLAYING;
        g.turn = uint8(_rand(id, 7) % 2) + 1;
        g.lastMove = uint64(block.timestamp);
        g.deadline = uint64(block.timestamp) + moveTimeout + firstMoveGrace;

        _removeOpen(id);
        gamesOf[msg.sender].push(id);
        escrowWei += stake;
        totalVolumeWei += stake * 2;

        emit GameJoined(id, msg.sender, g.turn);
        _sendExtra(msg.value - stake, session);
    }

    /// @notice Play against the computer. The house bank matches your stake. You are X.
    function playComputer(uint32 stakeCents, address session) external payable nonReentrant returns (uint256 id) {
        if (paused) revert Paused();
        if (!computerEnabled) revert ComputerOff();
        if (!validStake(stakeCents)) revert BadStake();
        uint256 stake = stakeWeiFor(stakeCents);
        if (msg.value < stake) revert FeeTooLow(stake, msg.value);
        if (houseBank < stake) revert HouseTooSmall();

        houseBank -= stake;
        escrowWei += stake * 2;
        totalVolumeWei += stake * 2;

        id = ++gameCount;
        Game storage g = games[id];
        g.playerX = msg.sender;
        g.playerO = address(this);
        g.sessionX = session;
        g.stakeWei = stake;
        g.stakeCents = stakeCents;
        g.status = PLAYING;
        g.winLine = 255;
        g.vsComputer = true;
        g.created = uint64(block.timestamp);
        gamesOf[msg.sender].push(id);

        uint8 first = uint8(_rand(id, 7) % 2) + 1;
        g.turn = first;
        emit GameCreated(id, msg.sender, stakeCents, stake);
        emit GameJoined(id, address(this), first);
        if (first == 2) {
            _computerMove(id, g); // computer opens
            g.deadline = uint64(block.timestamp) + moveTimeout + firstMoveGrace;
        } else {
            g.lastMove = uint64(block.timestamp);
            g.deadline = uint64(block.timestamp) + moveTimeout + firstMoveGrace;
        }
        _sendExtra(msg.value - stake, session);
    }

    /// @notice Anyone can add ETH to the house bank (used to match stakes in games vs the computer).
    function fundHouse() external payable {
        houseBank += msg.value;
        emit HouseFunded(msg.sender, msg.value, houseBank);
    }

    function withdrawHouse(uint256 amount) external onlyOwner nonReentrant {
        if (amount > houseBank) amount = houseBank;
        houseBank -= amount;
        emit HouseWithdrawn(amount, houseBank);
        (bool ok, ) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Creator can cancel a game nobody joined yet — full refund.
    function cancelGame(uint256 id) external nonReentrant {
        Game storage g = games[id];
        if (g.status != OPEN) revert NotOpen();
        if (msg.sender != g.playerX && (g.sessionX == address(0) || msg.sender != g.sessionX)) revert NotCreator();
        g.status = CANCELLED;
        _removeOpen(id);
        escrowWei -= g.stakeWei;
        emit GameCancelled(id);
        _pay(g.playerX, g.stakeWei);
    }

    // =====================================================================
    //                              PLAY
    // =====================================================================

    /// @notice Place your X or O. Costs the move fee. Must be within the time limit.
    function move(uint256 id, uint8 cell) external payable nonReentrant {
        Game storage g = games[id];
        if (g.status != PLAYING) revert NotPlaying();
        if ((_sideOf(g, msg.sender) & g.turn) == 0) revert NotYourTurn();
        if (block.timestamp > g.deadline) revert TooLate();
        if (cell > 8 || _cell(g.board, cell) != 0) revert BadCell();

        uint256 fee = moveFeeWei();
        if (msg.value < fee) revert FeeTooLow(fee, msg.value);
        totalFeesMicroUsd += moveFeeMicroUsd;

        _place(id, g, cell, false);
        _computerReply(id, g);
        if (msg.value > 0) _pay(owner, msg.value);
    }

    /// @notice When a player runs out of time, anyone can call this: the computer places a random mark for them.
    function forceMove(uint256 id) external nonReentrant {
        Game storage g = games[id];
        if (g.status != PLAYING) revert NotPlaying();
        if (block.timestamp <= g.deadline) revert NotYet();

        uint256 empty = 9 - g.moves;
        uint256 pick = _rand(id, g.moves) % empty;
        uint8 cell;
        for (uint8 i; i < 9; i++) {
            if (_cell(g.board, i) == 0) {
                if (pick == 0) { cell = i; break; }
                pick--;
            }
        }
        _place(id, g, cell, true);
        _computerReply(id, g);
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        totalPendingWei -= amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // =====================================================================
    //                              READS
    // =====================================================================

    function getGame(uint256 id) external view returns (Game memory) {
        return games[id];
    }

    /// @notice Game state plus the current chain time (for countdowns).
    function getGameNow(uint256 id) external view returns (Game memory g, uint256 nowTs) {
        return (games[id], block.timestamp);
    }

    function getGames(uint256[] calldata ids) external view returns (Game[] memory list) {
        list = new Game[](ids.length);
        for (uint256 i; i < ids.length; i++) list[i] = games[ids[i]];
    }

    function openGamesCount() external view returns (uint256) {
        return openIds.length;
    }

    function getOpenGames(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, Game[] memory list) {
        uint256 n = openIds.length;
        if (offset >= n) return (new uint256[](0), new Game[](0));
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        list = new Game[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = openIds[i];
            list[i - offset] = games[openIds[i]];
        }
    }

    /// @notice Latest games of a player (newest first).
    function getPlayerGames(address player, uint256 limit) external view returns (uint256[] memory ids, Game[] memory list) {
        uint256[] storage all = gamesOf[player];
        uint256 n = all.length < limit ? all.length : limit;
        ids = new uint256[](n);
        list = new Game[](n);
        for (uint256 i; i < n; i++) {
            uint256 id = all[all.length - 1 - i];
            ids[i] = id;
            list[i] = games[id];
        }
    }

    function info()
        external
        view
        returns (
            uint256 games_,
            uint256 finished_,
            uint256 volumeWei_,
            uint256 feesMicroUsd_,
            uint256 weiPerUsd_,
            uint256 moveFeeWei_,
            uint64 timeout_,
            uint32 minStake_,
            uint32 maxStake_,
            uint32 step_
        )
    {
        return (gameCount, finishedGames, totalVolumeWei, totalFeesMicroUsd, weiPerUsd(), moveFeeWei(), moveTimeout, minStakeCents, maxStakeCents, stakeStepCents);
    }

    function computerInfo() external view returns (bool enabled, uint8 mistakePct, uint256 bankWei, uint256 maxStakeCentsVsComputer) {
        uint256 wpu = weiPerUsd();
        uint256 maxC = wpu == 0 ? 0 : (houseBank * 100) / wpu;
        return (computerEnabled, computerMistakePct, houseBank, maxC);
    }

    // =====================================================================
    //                              ADMIN
    // =====================================================================

    function setMoveFee(uint256 microUsd) external onlyOwner {
        moveFeeMicroUsd = microUsd;
    }

    function setStakeLimits(uint32 minCents, uint32 maxCents, uint32 stepCents) external onlyOwner {
        require(minCents > 0 && minCents <= maxCents && stepCents > 0, "bad");
        minStakeCents = minCents;
        maxStakeCents = maxCents;
        stakeStepCents = stepCents;
    }

    function setTimeouts(uint64 _moveTimeout, uint64 _firstMoveGrace) external onlyOwner {
        require(_moveTimeout >= 5 && _moveTimeout <= 600 && _firstMoveGrace <= 600, "bad");
        moveTimeout = _moveTimeout;
        firstMoveGrace = _firstMoveGrace;
    }

    function setPriceFeed(address feed, uint256 _maxPriceAge) external onlyOwner {
        priceFeed = AggregatorV3Interface(feed);
        maxPriceAge = _maxPriceAge;
    }

    function setFallbackWeiPerUsd(uint256 value, bool _useFixedPrice) external onlyOwner {
        require(value > 0, "zero");
        fallbackWeiPerUsd = value;
        useFixedPrice = _useFixedPrice;
    }

    function setComputer(bool enabled, uint8 mistakePct) external onlyOwner {
        require(mistakePct <= 100, "bad");
        computerEnabled = enabled;
        computerMistakePct = mistakePct;
    }

    function setPaused(bool value) external onlyOwner {
        paused = value; // pausing blocks new games only; running games can always finish
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Sends ETH that is not part of any stake or pending payout (e.g. sent by mistake) to the owner.
    function sweepExtra() external onlyOwner nonReentrant {
        uint256 reserved = escrowWei + totalPendingWei + houseBank;
        uint256 bal = address(this).balance;
        if (bal <= reserved) revert NothingToWithdraw();
        (bool ok, ) = owner.call{value: bal - reserved}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}

    // =====================================================================
    //                              INTERNAL
    // =====================================================================

    function _place(uint256 id, Game storage g, uint8 cell, bool forced) private {
        uint8 side = g.turn;
        g.board |= uint32(side) << (cell * 2);
        g.moves += 1;
        if (forced) g.forcedMask |= uint16(1) << cell;
        emit Moved(id, side, cell, forced);

        uint8 line = _winLine(g.board, side);
        if (line != 255) {
            g.winLine = line;
            _finish(id, g, side == 1 ? X_WON : O_WON);
        } else if (g.moves == 9) {
            _finish(id, g, DRAW);
        } else {
            g.turn = 3 - side;
            g.lastMove = uint64(block.timestamp);
            g.deadline = uint64(block.timestamp) + moveTimeout;
        }
    }

    function _finish(uint256 id, Game storage g, uint8 result) private {
        g.status = result;
        g.lastMove = uint64(block.timestamp);
        uint256 stake = g.stakeWei;
        escrowWei -= stake * 2;
        finishedGames += 1;
        address px = g.playerX;
        if (g.vsComputer) {
            if (result == DRAW) {
                stats[px].draws += 1;
                houseBank += stake;
                emit GameFinished(id, result, address(0), stake);
                _pay(px, stake);
            } else if (result == X_WON) {
                stats[px].wins += 1;
                stats[px].wonWei += stake;
                emit GameFinished(id, result, px, stake * 2);
                _pay(px, stake * 2);
            } else {
                stats[px].losses += 1;
                houseBank += stake * 2;
                emit GameFinished(id, result, address(this), stake * 2);
            }
            return;
        }
        if (result == DRAW) {
            stats[px].draws += 1;
            stats[g.playerO].draws += 1;
            emit GameFinished(id, result, address(0), stake);
            _pay(px, stake);
            _pay(g.playerO, stake);
        } else {
            address winner = result == X_WON ? px : g.playerO;
            address loser = result == X_WON ? g.playerO : px;
            stats[winner].wins += 1;
            stats[winner].wonWei += stake;
            stats[loser].losses += 1;
            emit GameFinished(id, result, winner, stake * 2);
            _pay(winner, stake * 2);
        }
    }

    function _computerReply(uint256 id, Game storage g) private {
        if (g.vsComputer && g.status == PLAYING && g.turn == 2) _computerMove(id, g);
    }

    /// @dev Computer (O): take a win, usually block X, prefer center, else random.
    function _computerMove(uint256 id, Game storage g) private {
        uint32 b = g.board;
        uint256 r = _rand(id, 1000 + g.moves);
        uint8 cell = _findLineCell(b, 2);                 // 1. win if possible
        if (cell == 255 && (r % 100) >= computerMistakePct) cell = _findLineCell(b, 1); // 2. block
        if (cell == 255 && _cell(b, 4) == 0 && ((r >> 8) % 100) < 60) cell = 4;        // 3. center
        if (cell == 255) {                                 // 4. random empty
            uint256 pick = (r >> 16) % (9 - g.moves);
            for (uint8 i; i < 9; i++) {
                if (_cell(b, i) == 0) {
                    if (pick == 0) { cell = i; break; }
                    pick--;
                }
            }
        }
        _place(id, g, cell, false);
    }

    /// @dev Returns an empty cell that completes a line of `side`, or 255.
    function _findLineCell(uint32 b, uint8 side) private pure returns (uint8) {
        uint8[24] memory L = [0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 3, 6, 1, 4, 7, 2, 5, 8, 0, 4, 8, 2, 4, 6];
        for (uint8 l; l < 8; l++) {
            uint8 a = L[l * 3]; uint8 c = L[l * 3 + 1]; uint8 d = L[l * 3 + 2];
            uint8 va = _cell(b, a); uint8 vc = _cell(b, c); uint8 vd = _cell(b, d);
            if (va == side && vc == side && vd == 0) return d;
            if (va == side && vd == side && vc == 0) return c;
            if (vc == side && vd == side && va == 0) return a;
        }
        return 255;
    }

    /// @dev Push payment; if the receiver can't accept ETH it is kept for withdraw().
    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount, gas: 50_000}("");
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalPendingWei += amount;
        }
    }

    function _sendExtra(uint256 extra, address session) private {
        if (extra == 0) return;
        _pay(session != address(0) ? session : msg.sender, extra);
    }

    function _sideOf(Game storage g, address who) private view returns (uint8 s) {
        if (who == g.playerX || (g.sessionX != address(0) && who == g.sessionX)) s |= 1;
        if (who == g.playerO || (g.sessionO != address(0) && who == g.sessionO)) s |= 2;
    }

    function _cell(uint32 board, uint8 i) private pure returns (uint8) {
        return uint8((board >> (i * 2)) & 3);
    }

    function _winLine(uint32 b, uint8 side) private pure returns (uint8) {
        uint8[24] memory L = [0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 3, 6, 1, 4, 7, 2, 5, 8, 0, 4, 8, 2, 4, 6];
        for (uint8 l; l < 8; l++) {
            if (_cell(b, L[l * 3]) == side && _cell(b, L[l * 3 + 1]) == side && _cell(b, L[l * 3 + 2]) == side) return l;
        }
        return 255;
    }

    function _rand(uint256 id, uint256 salt) private view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, id, salt, msg.sender)));
    }

    function _removeOpen(uint256 id) private {
        uint256 idx = openIndex[id];
        if (idx == 0) return;
        uint256 last = openIds[openIds.length - 1];
        openIds[idx - 1] = last;
        openIndex[last] = idx;
        openIds.pop();
        openIndex[id] = 0;
    }
}
