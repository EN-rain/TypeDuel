const db = require('../config/db');

// Track online players by user_id with timestamps
const onlinePlayers = new Map();
const ONLINE_TIMEOUT_MS = 30000; // 30 seconds

const getLeaderboard = (req, res) => {
    const sql = 'SELECT users.username, leaderboard.wins, leaderboard.wpm, leaderboard.accuracy FROM leaderboard JOIN users ON leaderboard.user_id = users.id ORDER BY leaderboard.wins DESC LIMIT 10';
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
    const { user_id, session_id } = req.body;
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
    const { user_id, username, match_type, wpm, accuracy, typos, won } = req.body;
    if (!user_id) return res.status(400).json({ message: 'user_id required' });

    const sql = 'INSERT INTO match_history (user_id, username, match_type, wpm, accuracy, typos, won) VALUES (?, ?, ?, ?, ?, ?, ?)';
    db.run(sql, [user_id, username, match_type, wpm, accuracy, typos, won ? 1 : 0], function(err) {
        if (err) {
            console.error("Error saving match history:", err.message);
            return res.status(500).json({ message: 'Error saving match history' });
        }
        
        // Let's also update the leaderboard for wins if they won
        if (won) {
            db.get("SELECT * FROM leaderboard WHERE user_id = ?", [user_id], (err, row) => {
                if (!err && row) {
                    db.run("UPDATE leaderboard SET wins = wins + 1, wpm = ?, accuracy = ? WHERE user_id = ?", [wpm, accuracy, user_id]);
                } else if (!err && !row) {
                    db.run("INSERT INTO leaderboard (user_id, username, wins, wpm, accuracy) VALUES (?, ?, 1, ?, ?)", [user_id, username, wpm, accuracy]);
                }
            });
        }
        res.json({ message: 'Match history saved', id: this.lastID });
    });
};

const getMatchHistory = (req, res) => {
    const { user_id } = req.params;
    
    // Get all matches
    db.all("SELECT * FROM match_history WHERE user_id = ? ORDER BY created_at DESC", [user_id], (err, rows) => {
        if (err) {
            console.error("Error fetching match history:", err.message);
            return res.status(500).json({ message: 'Error fetching match history' });
        }
        
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
};

module.exports = { getLeaderboard, getOnlineCount, heartbeat, setOnline, setOffline, isUserOnline, saveMatchHistory, getMatchHistory };
