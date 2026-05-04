const sqlite3 = require('sqlite3');
const db = new sqlite3.Database(':memory:');
db.serialize(() => {
    db.run("CREATE TABLE chat_messages (id INTEGER, room_id TEXT, user_id INTEGER, is_read INTEGER)");
    db.run("INSERT INTO chat_messages VALUES (1, 'dm_2_10', 10, 0)");
    db.all(`SELECT COUNT(*) as unread_count FROM chat_messages cm WHERE cm.room_id = 'dm_' || MIN(?, 10) || '_' || MAX(?, 10) AND cm.user_id = 10 AND cm.is_read = 0`, [2, 2], (err, rows) => {
        console.log(rows);
    });
});
