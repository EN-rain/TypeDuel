const db = require('../config/db');

exports.sendMessage = (req, res) => {
    const user_id = req.user && req.user.id;
    const { room_id, message } = req.body;
    
    if (!user_id || !room_id || typeof message !== 'string' || message.trim() === '') {
        return res.status(400).json({ message: 'Missing fields' });
    }
    if (message.length > 1000) {
        return res.status(400).json({ message: 'Message is too long' });
    }

    db.get('SELECT username, display_name FROM users WHERE id = ?', [user_id], (userErr, user) => {
        if (userErr || !user) return res.status(500).json({ message: 'Database error' });
        const username = user.display_name || user.username;
        const query = `INSERT INTO chat_messages (user_id, username, room_id, message) VALUES (?, ?, ?, ?)`;
        db.run(query, [user_id, username, room_id, message.trim()], function(err) {
            if (err) {
                console.error('Error sending message:', err.message);
                return res.status(500).json({ message: 'Database error' });
            }
            res.status(201).json({ id: this.lastID });
        });
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

exports.markRead = (req, res) => {
    const { room_id } = req.body;
    const reader_user_id = req.user && req.user.id;
    if (!room_id || !reader_user_id) {
        return res.status(400).json({ message: 'Missing fields' });
    }
    // Mark all messages in the room NOT sent by this user as read
    db.run(
        `UPDATE chat_messages SET is_read = 1 WHERE room_id = ? AND user_id != ? AND is_read = 0`,
        [room_id, reader_user_id],
        function(err) {
            if (err) return res.status(500).json({ message: 'Database error' });
            res.status(200).json({ updated: this.changes });
        }
    );
};
