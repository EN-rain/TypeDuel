const db = require('../config/db');

exports.sendRequest = (req, res) => {
    const { user_id, friend_username } = req.body;
    
    // 1. Find the friend's user ID
    db.get("SELECT id FROM users WHERE username = ?", [friend_username], (err, friend) => {
        if (err) return res.status(500).json({ message: "Database error" });
        if (!friend) return res.status(404).json({ message: "User not found" });
        if (friend.id === user_id) return res.status(400).json({ message: "You can't add yourself" });

        // 2. Check if relationship already exists
        db.get("SELECT * FROM friends WHERE (user_id = ? AND friend_id = ?) OR (user_id = ? AND friend_id = ?)", 
            [user_id, friend.id, friend.id, user_id], (err, existing) => {
            if (err) return res.status(500).json({ message: "Database error" });
            if (existing) return res.status(400).json({ message: "Request already exists or you are already friends" });

            // 3. Insert pending request
            db.run("INSERT INTO friends (user_id, friend_id, status) VALUES (?, ?, 'pending')", 
                [user_id, friend.id], function(err) {
                if (err) return res.status(500).json({ message: "Database error" });
                res.status(200).json({ message: "Friend request sent" });
            });
        });
    });
};

exports.acceptRequest = (req, res) => {
    const { user_id, friend_id } = req.body;
    db.run("UPDATE friends SET status = 'accepted' WHERE user_id = ? AND friend_id = ? AND status = 'pending'", 
        [friend_id, user_id], function(err) {
        if (err) return res.status(500).json({ message: "Database error" });
        if (this.changes === 0) return res.status(404).json({ message: "Request not found" });
        res.status(200).json({ message: "Friend request accepted" });
    });
};

exports.removeFriend = (req, res) => {
    const { user_id, friend_id } = req.body;
    db.run("DELETE FROM friends WHERE (user_id = ? AND friend_id = ?) OR (user_id = ? AND friend_id = ?)", 
        [user_id, friend_id, friend_id, user_id], function(err) {
        if (err) return res.status(500).json({ message: "Database error" });
        res.status(200).json({ message: "Friend removed" });
    });
};

exports.getFriends = (req, res) => {
    const user_id = parseInt(req.params.user_id, 10);
    if (isNaN(user_id)) return res.status(400).json({ message: "Invalid user_id" });
    const query = `
        SELECT 
            f.id as relation_id, 
            f.status, 
            u.id as user_id, 
            u.username, 
            u.display_name,
            u.profile_icon,
            CASE 
                WHEN u.last_active > datetime('now', '-1 minute') THEN 1 
                ELSE 0 
            END as is_online,
            CASE WHEN f.friend_id = ? THEN 1 ELSE 0 END as is_incoming_request,
            (SELECT COUNT(*) 
             FROM chat_messages cm 
             WHERE cm.room_id = 'dm_' || MIN(?, u.id) || '_' || MAX(?, u.id)
               AND cm.user_id = u.id 
               AND cm.is_read = 0) as unread_count,
            CASE WHEN EXISTS (
                SELECT 1
                FROM chat_messages cm2
                WHERE cm2.room_id = 'dm_' || MIN(?, u.id) || '_' || MAX(?, u.id)
            ) THEN 1 ELSE 0 END as has_chat
        FROM friends f
        JOIN users u ON (f.user_id = u.id OR f.friend_id = u.id)
        WHERE (f.user_id = ? OR f.friend_id = ?) AND u.id != ?
    `;
    db.all(query, [user_id, user_id, user_id, user_id, user_id, user_id, user_id, user_id], (err, rows) => {
        if (err) return res.status(500).json({ message: "Database error" });
        res.status(200).json(rows);
    });
};
