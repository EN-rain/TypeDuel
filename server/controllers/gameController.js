const db = require('../config/db');

// Track online players by user_id with timestamps
const onlinePlayers = new Map();
const ONLINE_TIMEOUT_MS = 30000; // 30 seconds

const getLeaderboard = (req, res) => {
    const sql = 'SELECT username, wins, wpm, accuracy FROM leaderboard ORDER BY wins DESC LIMIT 10';
    db.all(sql, [], (err, rows) => {
        if (err) {
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
    const key = session_id ? String(session_id) : String(user_id);
    onlinePlayers.set(key, Date.now());
    res.json({ ok: true });
};

const setOnline = (userId) => onlinePlayers.set(String(userId), Date.now());
const setOffline = (userId) => onlinePlayers.delete(String(userId));

module.exports = { getLeaderboard, getOnlineCount, heartbeat, setOnline, setOffline };
