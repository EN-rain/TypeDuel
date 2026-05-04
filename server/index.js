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

// Request Logging Middleware
app.use((req, res, next) => {
    console.log(`${new Date().toISOString()} - ${req.method} ${req.url}`);
    next();
});

// Serve static files from uploads directory
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));

// Routes
app.use('/api/auth', authRoutes);
app.use('/api/game', gameRoutes);
app.use('/api/rooms', roomRoutes);
app.use('/api/chat', chatRoutes);
app.use('/api/friends', friendsRoutes);


// Database Initialization
const initDb = () => {
    const schema = fs.readFileSync(path.join(__dirname, 'database', 'schema.sql'), 'utf8');
    db.exec(schema, (err) => {
        if (err) {
            console.error('Error initializing database:', err.message);
        } else {
            console.log('Database initialized');
            
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
});

// Global Error Handler
app.use((err, req, res, next) => {
    console.error(err.stack);
    res.status(500).json({ message: 'Something went wrong!' });
});
