const db = require('../config/db');
const jwt = require('jsonwebtoken');

const register = (req, res) => {
  const { username, password, email } = req.body;
  
  // Alphanumeric check
  const usernameRegex = /^[a-zA-Z0-9_]+$/;
  if (!usernameRegex.test(username)) {
    return res.status(400).json({ message: 'Username can only contain letters, numbers, and underscores' });
  }

  const sql = 'INSERT INTO users (username, password, display_name, email) VALUES (?, ?, ?, ?)';
  db.run(sql, [username, password, username, email], function(err) {
    if (err) {
      return res.status(400).json({ message: 'User already exists or invalid data' });
    }
    const userId = this.lastID;
    const token = jwt.sign({ id: userId, username }, process.env.JWT_SECRET || 'secret', { expiresIn: '1h' });
    res.status(201).json({ token, user: { id: userId, username, display_name: username } });
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
    res.json({ token, user: { id: user.id, username: user.username, display_name: user.display_name || user.username } });
  });
};

const updateProfile = (req, res) => {
  const { userId, newPassword, newDisplayName } = req.body;
  
  if (!userId) return res.status(400).json({ message: 'User ID required' });

  let sql = 'UPDATE users SET display_name = ?';
  let params = [newDisplayName];

  if (newPassword && newPassword.length > 0) {
    sql += ', password = ?';
    params.push(newPassword);
  }

  sql += ' WHERE id = ?';
  params.push(userId);

  db.run(sql, params, function(err) {
    if (err) {
      return res.status(500).json({ message: 'Error updating profile' });
    }
    res.json({ message: 'Profile updated successfully', display_name: newDisplayName });
  });
};

module.exports = { register, login, updateProfile };
