const db = require('../config/db');
const jwt = require('jsonwebtoken');
const { isUserOnline, setOnline, setOffline } = require('./gameController');

const crypto = require('crypto');

const register = (req, res) => {
  const { username, password, email } = req.body;
  
  // Alphanumeric check
  const usernameRegex = /^[a-zA-Z0-9_]+$/;
  if (!usernameRegex.test(username)) {
    return res.status(400).json({ message: 'Username can only contain letters, numbers, and underscores' });
  }

  const session_token = crypto.randomUUID();
  const sql = 'INSERT INTO users (username, password, display_name, email, session_token) VALUES (?, ?, ?, ?, ?)';
  db.run(sql, [username, password, username, email, session_token], function(err) {
    if (err) {
      if (err.message && err.message.includes('UNIQUE constraint failed: users.username')) {
        return res.status(400).json({ message: 'Username is already taken. Please choose another one.' });
      }
      return res.status(400).json({ message: 'User already exists or invalid data' });
    }
    const userId = this.lastID;
    const token = jwt.sign({ id: userId, username, session_token }, process.env.JWT_SECRET || 'secret', { expiresIn: '1h' });
    setOnline(userId);
    res.status(201).json({ token, user: { id: userId, username, display_name: username, profile_icon: 'default' } });
  });
};

const login = (req, res) => {
  const { username, password } = req.body;
  const sql = 'SELECT * FROM users WHERE username = ? AND password = ?';
  db.get(sql, [username, password], (err, user) => {
    if (err || !user) {
      return res.status(400).json({ message: 'Invalid credentials' });
    }
    
    // Update session_token to allow re-login from same or new device
    // (This automatically handles "ghost" sessions if the game crashed)
    
    const session_token = crypto.randomUUID();
    db.run('UPDATE users SET session_token = ? WHERE id = ?', [session_token, user.id], (updateErr) => {
      const token = jwt.sign({ id: user.id, username: user.username, session_token }, process.env.JWT_SECRET || 'secret', { expiresIn: '1h' });
      setOnline(user.id);
      res.json({ 
        token, 
        user: { 
          id: user.id, 
          username: user.username, 
          display_name: user.display_name || user.username,
          profile_icon: user.profile_icon || 'default'
        } 
      });
    });
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

const uploadPfp = (req, res) => {
  const { userId } = req.body;
  if (!userId) return res.status(400).json({ message: 'User ID required' });
  if (!req.file) return res.status(400).json({ message: 'No file uploaded' });

  const profileIcon = req.file.filename;
  const sql = 'UPDATE users SET profile_icon = ? WHERE id = ?';
  
  db.run(sql, [profileIcon, userId], function(err) {
    if (err) {
      return res.status(500).json({ message: 'Error updating profile picture' });
    }
    res.json({ message: 'Profile picture updated successfully', profile_icon: profileIcon });
  });
};

const logout = (req, res) => {
  const { user_id } = req.body;
  if (user_id) {
    setOffline(user_id);
    console.log(`User ${user_id} logged out and marked offline.`);
  }
  res.json({ ok: true });
};

module.exports = { register, login, updateProfile, uploadPfp, logout };
