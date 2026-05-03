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

module.exports = { getLeaderboard };
