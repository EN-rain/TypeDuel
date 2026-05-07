const db = require('../config/db');

function hasColumn(cols, name) {
    return cols.some(c => c.name === name);
}

db.serialize(() => {
    db.all("PRAGMA table_info(users)", (err, rows) => {
        if (err) { console.error(err); return; }

        const missing = [];

        if (!hasColumn(rows, 'display_name')) missing.push("ALTER TABLE users ADD COLUMN display_name TEXT");
        if (!hasColumn(rows, 'last_active'))  missing.push("ALTER TABLE users ADD COLUMN last_active DATETIME");
        if (!hasColumn(rows, 'profile_icon')) missing.push("ALTER TABLE users ADD COLUMN profile_icon TEXT DEFAULT 'default'");
        // server-side matchmaking penalty column
        if (!hasColumn(rows, 'matchmaking_penalty_until')) missing.push("ALTER TABLE users ADD COLUMN matchmaking_penalty_until INTEGER DEFAULT 0");

        if (missing.length === 0) {
            console.log("Schema is up to date.");
        } else {
            console.log(`Applying ${missing.length} missing column(s)...`);
        }

        missing.forEach(sql => {
            db.run(sql, (err) => {
                if (err) console.error("Migration error:", err.message);
                else console.log("Applied:", sql);
            });
        });

        // Backfill display_name from username for existing users
        db.run("UPDATE users SET display_name = username WHERE display_name IS NULL", (err) => {
            if (!err) console.log("Backfilled display_name for existing users.");
        });
    });

    db.all("PRAGMA table_info(chat_messages)", (err, rows) => {
        if (err) { console.error(err); return; }

        if (!hasColumn(rows, 'is_read')) {
            db.run("ALTER TABLE chat_messages ADD COLUMN is_read BOOLEAN DEFAULT 0", (err) => {
                if (err) console.error("Migration error:", err.message);
                else console.log("Applied: ALTER TABLE chat_messages ADD COLUMN is_read BOOLEAN DEFAULT 0");
            });
        }
    });
});
