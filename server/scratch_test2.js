const sqlite3 = require('sqlite3');
const db = new sqlite3.Database(':memory:');
db.serialize(() => {
    db.run("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT)");
    db.run("INSERT INTO users VALUES (1, 'alice'), (2, 'bob')");
    
    db.run("CREATE TABLE friends (user_id INTEGER, friend_id INTEGER, status TEXT)");
    db.run("INSERT INTO friends VALUES (1, 2, 'accepted')");
    
    db.run("CREATE TABLE chat_messages (id INTEGER, room_id TEXT, user_id INTEGER, is_read INTEGER)");
    db.run("INSERT INTO chat_messages VALUES (1, 'dm_1_2', 2, 0)"); // bob sent to alice
    
    const user_id = 1;
    const query = `
        SELECT 
            u.id as user_id, 
            (SELECT COUNT(*) 
             FROM chat_messages cm 
             WHERE cm.room_id = 'dm_' || MIN(?, u.id) || '_' || MAX(?, u.id)
               AND cm.user_id = u.id 
               AND cm.is_read = 0) as unread_count
        FROM friends f
        JOIN users u ON (f.user_id = u.id OR f.friend_id = u.id)
        WHERE (f.user_id = ? OR f.friend_id = ?) AND u.id != ?
    `;
    db.all(query, [user_id, user_id, user_id, user_id, user_id], (err, rows) => {
        console.log(rows);
    });
});
