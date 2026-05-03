require('dotenv').config();
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const db = require('./config/db');
const authRoutes = require('./routes/auth');
const socketHandler = require('./socket');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

// Middleware
app.use(cors());
app.use(express.json());

// Initialize Database Table (if not exists)
const fs = require('fs');
const path = require('path');
const schema = fs.readFileSync(path.join(__dirname, 'database/schema.sql'), 'utf8');
db.exec(schema, (err) => {
  if (err) console.error('Error initializing database', err);
  else console.log('Database initialized');
});

// Routes
app.use('/api/auth', authRoutes);

// WebSocket
socketHandler(io);

// Global Error Handler
app.use((err, req, res, next) => {
  console.error(err.stack);
  res.status(500).json({ message: 'Something went wrong on the server' });
});

// Auto-seed if empty
db.get("SELECT COUNT(*) as count FROM users", (err, row) => {
    if (!err && row && row.count === 0) {
        console.log("Database empty, auto-seeding dummy data...");
        require('./scripts/seed');
    }
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
