const db = require('../config/db');

// Track online players by user_id with timestamps
const onlinePlayers = new Map();
const ONLINE_TIMEOUT_MS = 20000; // 20 seconds (heartbeat is every 15s)

const getLeaderboard = (req, res) => {
    const sql = `
        SELECT users.username, leaderboard.wins, leaderboard.wpm, leaderboard.accuracy
        FROM leaderboard
        JOIN users ON leaderboard.user_id = users.id
        ORDER BY leaderboard.wins DESC, leaderboard.wpm DESC, leaderboard.accuracy DESC
        LIMIT 10
    `;
    db.all(sql, [], (err, rows) => {
        if (err) {
            console.error("Leaderboard query error:", err.message);
            return res.status(500).json({ message: 'Error fetching leaderboard' });
        }
        res.json(rows);
    });
};

const getOnlineCount = (req, res) => {
    const now = Date.now();
    let count = 0;
    for (const [id, lastSeen] of onlinePlayers) {
        if (now - lastSeen < ONLINE_TIMEOUT_MS) {
            count++;
        } else {
            onlinePlayers.delete(id);
        }
    }
    res.json({ online: count });
};

const heartbeat = (req, res) => {
    const { session_id } = req.body;
    const user_id = req.user && req.user.id;
    if (!user_id && !session_id) return res.status(400).json({ message: 'user_id or session_id required' });
    
    let key;
    if (user_id && user_id !== 0) {
        key = "user_" + String(user_id);
    } else {
        key = "session_" + String(session_id);
    }
    
    onlinePlayers.set(key, Date.now());
    
    // Also update database for persistent status tracking
    if (user_id && user_id !== 0) {
        db.run("UPDATE users SET last_active = CURRENT_TIMESTAMP WHERE id = ?", [user_id]);
    }
    
    res.json({ ok: true });
};


const setOnline = (userId) => onlinePlayers.set("user_" + String(userId), Date.now());
const setOffline = (userId) => onlinePlayers.delete("user_" + String(userId));
const isUserOnline = (userId) => {
    const lastSeen = onlinePlayers.get("user_" + String(userId));
    return lastSeen && (Date.now() - lastSeen < ONLINE_TIMEOUT_MS);
};

const saveMatchHistory = (req, res) => {
    if (!req.body || req.body.is_solo !== true) {
        return res.status(403).json({ message: 'Only server-authoritative results may be saved for multiplayer matches' });
    }
    const { username, match_type, wpm, accuracy, typos, won } = req.body;
    const user_id = req.user && req.user.id;
    if (!user_id) return res.status(401).json({ message: 'Not authenticated' });

    const userIdNum = Number(user_id);
    if (!Number.isFinite(userIdNum) || userIdNum <= 0) {
        return res.status(400).json({ message: 'user_id must be a positive number' });
    }

    const safeUsername = (typeof username === 'string' && username.trim() !== '') ? username.trim() : String(userIdNum);
    const safeMatchType = (match_type === 'online' || match_type === 'custom') ? match_type : 'online';

    const wpmNum = Number(wpm);
    const accNum = Number(accuracy);
    const typosNum = Number(typos);
    if (!Number.isFinite(wpmNum) || wpmNum < 0) return res.status(400).json({ message: 'wpm must be a non-negative number' });
    if (!Number.isFinite(accNum) || accNum < 0 || accNum > 100) return res.status(400).json({ message: 'accuracy must be 0..100' });
    if (!Number.isFinite(typosNum) || typosNum < 0) return res.status(400).json({ message: 'typos must be a non-negative number' });

    if (typeof won !== 'boolean') {
        return res.status(400).json({ message: 'won must be boolean' });
    }

    const sql = 'INSERT INTO match_history (user_id, username, match_type, wpm, accuracy, typos, won) VALUES (?, ?, ?, ?, ?, ?, ?)';
    db.run(sql, [userIdNum, safeUsername, safeMatchType, wpmNum, accNum, typosNum, won ? 1 : 0], function(err) {
        if (err) {
            console.error("Error saving match history:", err.message);
            return res.status(500).json({ message: 'Error saving match history' });
        }
        
        // Let's also update the leaderboard for wins if they won
        if (won) {
            db.get("SELECT * FROM leaderboard WHERE user_id = ?", [userIdNum], (err, row) => {
                if (!err && row) {
                    db.run("UPDATE leaderboard SET wins = wins + 1, wpm = ?, accuracy = ? WHERE user_id = ?", [wpmNum, accNum, userIdNum]);
                } else if (!err && !row) {
                    db.run("INSERT INTO leaderboard (user_id, username, wins, wpm, accuracy) VALUES (?, ?, 1, ?, ?)", [userIdNum, safeUsername || String(userIdNum), wpmNum, accNum]);
                }
            });
        }
        res.json({ message: 'Match history saved', id: this.lastID });
    });
};

const getMatchHistory = (req, res) => {
    const { user_id } = req.params;
    const userIdNum = Number(user_id);
    if (!Number.isFinite(userIdNum) || userIdNum <= 0) {
        return res.status(400).json({ message: 'Invalid user_id' });
    }
    
    // Authorization: User can read their own history, OR if they are friends
    const requesterId = req.user && req.user.id;
    if (!requesterId) return res.status(401).json({ message: 'Not authenticated' });

    const isOwnHistory = userIdNum === Number(requesterId);
    
    const checkAccess = () => {
        if (isOwnHistory) return Promise.resolve(true);
        return new Promise((resolve) => {
            db.get("SELECT status FROM friends WHERE ((user_id = ? AND friend_id = ?) OR (user_id = ? AND friend_id = ?)) AND status = 'accepted'",
                [requesterId, userIdNum, userIdNum, requesterId], (err, row) => {
                    if (err || !row) resolve(false);
                    else resolve(true);
                });
        });
    };

    checkAccess().then(hasAccess => {
        if (!hasAccess) {
            return res.status(403).json({ message: 'Cannot read history: Not friends' });
        }

        // Get all matches
        db.all("SELECT * FROM match_history WHERE user_id = ? ORDER BY created_at DESC", [userIdNum], (err, rows) => {
            if (err) {
                console.error("Error fetching match history:", err.message);
                return res.status(500).json({ message: 'Error fetching match history' });
            }

            // Sanitize null/invalid values so the Godot UI doesn't crash on formatting.
            rows = rows.map(r => ({
                ...r,
                match_type: (r.match_type === 'online' || r.match_type === 'custom') ? r.match_type : 'online',
                wpm: Number.isFinite(Number(r.wpm)) ? Number(r.wpm) : 0,
                accuracy: Number.isFinite(Number(r.accuracy)) ? Number(r.accuracy) : 0,
                typos: Number.isFinite(Number(r.typos)) ? Number(r.typos) : 0,
                won: !!r.won,
            }));
            
            // Calculate overall stats
            let totalWpm = 0;
            let totalAccuracy = 0;
            let totalTypos = 0;
            let totalWins = 0;
            
            rows.forEach(row => {
                totalWpm += row.wpm;
                totalAccuracy += row.accuracy;
                totalTypos += row.typos;
                if (row.won) totalWins++;
            });
            
            const count = rows.length;
            const stats = {
                total_matches: count,
                total_wins: totalWins,
                avg_wpm: count > 0 ? (totalWpm / count) : 0,
                avg_accuracy: count > 0 ? (totalAccuracy / count) : 0,
                total_typos: totalTypos
            };
            
            res.json({ stats, history: rows });
        });
    });
};

// HTTP endpoint to apply a matchmaking penalty for a user.
// This endpoint is intentionally called ONLY from the matchmaking flow
// (custom_room.gd → _apply_matchmaking_penalty, gated by GameManager.is_matchmaking).
// Custom-room players are never penalized — the client never calls this endpoint for them.
const applyMatchmakingPenalty = (req, res) => {
    const { user_id, duration_ms } = req.body;

    // Authenticated-only: do not allow a client to penalize someone else.
    const actorId = req.user && req.user.id;
    if (actorId === undefined || actorId === null) {
        return res.status(401).json({ message: 'Not authenticated' });
    }
    if (user_id !== undefined && String(user_id) !== String(actorId)) {
        return res.status(403).json({ message: 'user_id does not match authenticated user' });
    }

    const userIdNum = Number(user_id);
    if (!Number.isFinite(userIdNum) || userIdNum <= 0) {
        return res.status(400).json({ message: 'user_id must be a positive number' });
    }
    const dur = Number(duration_ms);
    const safeDur = Number.isFinite(dur) && dur > 0 ? Math.min(dur, 60000) : 10000; // cap at 60s
    setMatchmakingPenalty(userIdNum, safeDur);
    res.json({ ok: true, penalty_until: Date.now() + safeDur });
};

// DEV ONLY: clear all online sessions instantly (for debug resets)
const clearAllOnline = (req, res) => {
    if (process.env.NODE_ENV === 'production') {
        return res.status(404).json({ message: 'Not found' });
    }
    const count = onlinePlayers.size;
    onlinePlayers.clear();
    console.log(`[DEV] Cleared ${count} online session(s).`);
    res.json({ ok: true, cleared: count });
};

// set a server-side matchmaking penalty for a user (unix ms)
const setMatchmakingPenalty = (userId, durationMs) => {
    const until = Date.now() + durationMs;
    db.run('UPDATE users SET matchmaking_penalty_until = ? WHERE id = ?', [until, userId], (err) => {
        if (err) console.error('[Penalty] Failed to set penalty:', err.message);
    });
};

// check if a user is currently penalised (returns Promise<bool>)
const isMatchmakingPenalized = (userId) => new Promise((resolve) => {
    db.get('SELECT matchmaking_penalty_until FROM users WHERE id = ?', [userId], (err, row) => {
        if (err || !row) return resolve(false);
        resolve(Date.now() < (row.matchmaking_penalty_until || 0));
    });
});

module.exports = { getLeaderboard, getOnlineCount, heartbeat, setOnline, setOffline, isUserOnline, saveMatchHistory, getMatchHistory, clearAllOnline, setMatchmakingPenalty, isMatchmakingPenalized, applyMatchmakingPenalty };
