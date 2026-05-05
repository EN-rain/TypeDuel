require('dotenv').config();
const express = require('express');
const cors = require('cors');
const db = require('./config/db');
const authRoutes = require('./routes/auth');
const gameRoutes = require('./routes/game');
const roomRoutes = require('./routes/rooms');
const chatRoutes = require('./routes/chat');
const friendsRoutes = require('./routes/friends');

const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());

if (process.env.LOG_REQUESTS === 'true') {
    app.use((req, res, next) => {
        console.log(`${new Date().toISOString()} - ${req.method} ${req.url}`);
        next();
    });
}

// Serve static files from uploads directory
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

// Routes
app.use('/api/auth', authRoutes);
app.use('/api/game', gameRoutes);
app.use('/api/rooms', roomRoutes);
app.use('/api/chat', chatRoutes);
app.use('/api/friends', friendsRoutes);
app.get('/api/health', (req, res) => res.sendStatus(200));


// Database Initialization
const initDb = () => {
    const schema = fs.readFileSync(path.join(__dirname, 'database', 'schema.sql'), 'utf8');
    db.exec(schema, (err) => {
        if (err) {
            console.error('Error initializing database:', err.message);
        } else {
            console.log('Database initialized');
            
            // Fix #10: run migrations to add any new columns to existing databases
            require('./scripts/migrate');

            // Check if seeding is needed
            db.get('SELECT COUNT(*) as count FROM users', (err, row) => {
                if (!err && row.count === 0) {
                    console.log('Database empty, running seed script...');
                    require('./scripts/seed');
                }
            });
        }
    });
};

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
    console.log('Connected to SQLite database');
    initDb();

    // Fix #11: only purge global chat messages, not DMs.
    // DM room IDs follow the pattern 'dm_<id>_<id>'; global chat uses 'global'.
    // This prevents users losing private conversation history.
    const purgeOldMessages = () => {
        db.run(
            `DELETE FROM chat_messages WHERE room_id NOT LIKE 'dm_%' AND created_at < datetime('now', '-12 hours')`,
            function(err) {
                if (err) {
                    console.error('Chat purge error:', err.message);
                } else if (this.changes > 0) {
                    console.log(`Purged ${this.changes} old global chat message(s).`);
                }
            }
        );
    };

    purgeOldMessages(); // Run once on startup
    setInterval(purgeOldMessages, 60 * 60 * 1000); // Then every hour

    // Purge unused uploads older than 12 hours
    const purgeOldUploads = () => {
        const uploadsDir = path.join(__dirname, 'uploads');
        if (!fs.existsSync(uploadsDir)) return;

        db.all('SELECT DISTINCT profile_icon FROM users WHERE profile_icon IS NOT NULL AND profile_icon != "default"', (err, rows) => {
            if (err) {
                console.error('Upload purge DB error:', err.message);
                return;
            }

            const activeIcons = new Set(rows.map(row => row.profile_icon));
            const now = Date.now();
            const TWELVE_HOURS = 12 * 60 * 60 * 1000;

            fs.readdir(uploadsDir, (err, files) => {
                if (err) return;
                files.forEach(file => {
                    if (file.startsWith('.') || activeIcons.has(file)) return;
                    const filePath = path.join(uploadsDir, file);
                    fs.stat(filePath, (err, stats) => {
                        if (!err && (now - stats.mtimeMs > TWELVE_HOURS)) {
                            fs.unlink(filePath, (err) => {
                                if (!err) console.log(`Purged unused upload: ${file}`);
                            });
                        }
                    });
                });
            });
        });
    };

    purgeOldUploads();
    setInterval(purgeOldUploads, 60 * 60 * 1000); // Check every hour
});

// Global Error Handler
app.use((err, req, res, next) => {
    console.error(err.stack);
    res.status(500).json({ message: 'Something went wrong!' });
});
