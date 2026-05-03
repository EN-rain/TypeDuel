const db = require('../config/db');
const jwt = require('jsonwebtoken');

const register = (req, res) => {
  const { username, password, email } = req.body;
  
  // Alphanumeric check
  const usernameRegex = /^[a-zA-Z0-9_]+$/;
  if (!usernameRegex.test(username)) {
    return res.status(400).json({ message: 'Username can only contain letters, numbers, and underscores' });
  }

  const sql = 'INSERT INTO users (username, password, email) VALUES (?, ?, ?)';
  db.run(sql, [username, password, email], function(err) {
    if (err) {
      return res.status(400).json({ message: 'User already exists or invalid data' });
    }
    res.status(201).json({ id: this.lastID, username });
  });
};

const login = (req, res) => {
  const { username, password } = req.body;
  const sql = 'SELECT * FROM users WHERE username = ? AND password = ?';
  db.get(sql, [username, password], (err, user) => {
    if (err || !user) {
      return res.status(400).json({ message: 'Invalid credentials' });
    }
    const token = jwt.sign({ id: user.id, username: user.username }, process.env.JWT_SECRET || 'secret', { expiresIn: '1h' });
    res.json({ token, user: { id: user.id, username: user.username } });
  });
};

module.exports = { register, login }; 
