const db = require('../config/db');

const getLeaderboard = (req, res) => {
    const sql = 'SELECT username, wins, wpm, accuracy FROM leaderboard ORDER BY wins DESC LIMIT 10';
    db.all(sql, [], (err, rows) => {
        if (err) {
            return res.status(500).json({ message: 'Error fetching leaderboard' });
        }
        res.json(rows);
    });
};

// In-memory online player tracker (keyed by user token)
const onlinePlayers = new Set();

const getOnlineCount = (req, res) => {
    res.json({ online: onlinePlayers.size });
};

const setOnline = (token) => onlinePlayers.add(token);
const setOffline = (token) => onlinePlayers.delete(token);

module.exports = { getLeaderboard, getOnlineCount, setOnline, setOffline };
