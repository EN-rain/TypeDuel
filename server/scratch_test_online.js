const sqlite3 = require('sqlite3');
const db = new sqlite3.Database(':memory:');
db.serialize(() => {
    db.run("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT, last_active DATETIME)");
    // Set both to be online
    db.run("INSERT INTO users VALUES (1, 'alice', datetime('now')), (2, 'bob', datetime('now'))");
    
    db.run("CREATE TABLE friends (id INTEGER PRIMARY KEY, user_id INTEGER, friend_id INTEGER, status TEXT)");
    db.run("INSERT INTO friends (user_id, friend_id, status) VALUES (1, 2, 'accepted')");
    
    db.run("CREATE TABLE chat_messages (id INTEGER PRIMARY KEY, room_id TEXT, user_id INTEGER, is_read INTEGER)");
    // bob sends to alice
    db.run("INSERT INTO chat_messages (room_id, user_id, is_read) VALUES ('dm_1_2', 2, 0)");
    
    const user_id = 1;
    const query = `
        SELECT 
            f.id as relation_id, 
            f.status, 
            u.id as user_id, 
            u.username, 
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
        if (err) { console.error(err); }
        console.log(rows);
    });
});
