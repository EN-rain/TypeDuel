const db = require('../config/db');

exports.sendMessage = (req, res) => {
    const { user_id, username, room_id, message } = req.body;
    
    if (!user_id || !username || !room_id || !message) {
        return res.status(400).json({ message: 'Missing fields' });
    }

    const query = `INSERT INTO chat_messages (user_id, username, room_id, message) VALUES (?, ?, ?, ?)`;
    db.run(query, [user_id, username, room_id, message], function(err) {
        if (err) {
            console.error('Error sending message:', err.message);
            return res.status(500).json({ message: 'Database error' });
        }
        res.status(201).json({ id: this.lastID });
    });
};

exports.getMessages = (req, res) => {
    const { room_id } = req.query;
    const since = req.query.since || 0;
    
    if (!room_id) {
        return res.status(400).json({ message: 'Missing room_id' });
    }

    const query = `
        SELECT cm.*, u.profile_icon 
        FROM chat_messages cm 
        LEFT JOIN users u ON cm.user_id = u.id 
        WHERE cm.room_id = ? AND cm.id > ? 
        ORDER BY cm.created_at ASC LIMIT 50
    `;
    db.all(query, [room_id, since], (err, rows) => {
        if (err) {
            console.error('Error fetching messages:', err.message);
            return res.status(500).json({ message: 'Database error' });
        }
        res.status(200).json(rows);
    });
};
