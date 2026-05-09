const db = require('../config/db');
const jwt = require('jsonwebtoken');
const { isUserOnline, setOnline, setOffline } = require('./gameController');
const { getJwtSecret } = require('../utils/jwtSecret');

const crypto = require('crypto');

function hashPassword(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(password, salt, 64).toString('hex');
  return `scrypt$${salt}$${hash}`;
}

function verifyPassword(password, storedPassword) {
  if (typeof storedPassword !== 'string') return false;
  const parts = storedPassword.split('$');
  if (parts.length === 3 && parts[0] === 'scrypt') {
    const hash = crypto.scryptSync(password, parts[1], 64);
    const stored = Buffer.from(parts[2], 'hex');
    return stored.length === hash.length && crypto.timingSafeEqual(stored, hash);
  }
  return storedPassword === password;
}

const register = (req, res) => {
  const { username, password, email } = req.body;
  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(400).json({ message: 'Username and password required' });
  }
  if (password.length < 6 || password.length > 128) {
    return res.status(400).json({ message: 'Password must be 6-128 characters' });
  }
  
  // Alphanumeric check
  const usernameRegex = /^[a-zA-Z0-9_]+$/;
  if (!usernameRegex.test(username)) {
    return res.status(400).json({ message: 'Username can only contain letters, numbers, and underscores' });
  }

  const session_token = crypto.randomUUID();
  const passwordHash = hashPassword(password);
  const sql = 'INSERT INTO users (username, password, display_name, email, session_token) VALUES (?, ?, ?, ?, ?)';
  db.run(sql, [username, passwordHash, username, email, session_token], function(err) {
    if (err) {
      if (err.message && err.message.includes('UNIQUE constraint failed: users.username')) {
        return res.status(400).json({ message: 'Username is already taken. Please choose another one.' });
      }
      return res.status(400).json({ message: 'User already exists or invalid data' });
    }
    const userId = this.lastID;
    const token = jwt.sign({ id: userId, username, session_token }, getJwtSecret(), { expiresIn: '1h' });
    setOnline(userId);
    res.status(201).json({ token, user: { id: userId, username, display_name: username, profile_icon: 'default' } });
  });
};

const login = (req, res) => {
  const { username, password } = req.body;
  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(400).json({ message: 'Invalid credentials' });
  }
  const sql = 'SELECT * FROM users WHERE username = ?';
  db.get(sql, [username], (err, user) => {
    if (err || !user || !verifyPassword(password, user.password)) {
      return res.status(400).json({ message: 'Invalid credentials' });
    }
    
    // Update session_token to allow re-login from same or new device
    // (This automatically handles "ghost" sessions if the game crashed)
    
    const session_token = crypto.randomUUID();
    const needsPasswordUpgrade = typeof user.password === 'string' && !user.password.startsWith('scrypt$');
    const updateSql = needsPasswordUpgrade
      ? 'UPDATE users SET session_token = ?, password = ? WHERE id = ?'
      : 'UPDATE users SET session_token = ? WHERE id = ?';
    const updateParams = needsPasswordUpgrade
      ? [session_token, hashPassword(password), user.id]
      : [session_token, user.id];
    db.run(updateSql, updateParams, (updateErr) => {
      const token = jwt.sign({ id: user.id, username: user.username, session_token }, getJwtSecret(), { expiresIn: '1h' });
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
  const { newPassword, newDisplayName } = req.body;
  const userId = req.user && req.user.id;
  
  if (!userId) return res.status(400).json({ message: 'User ID required' });
  if (typeof newDisplayName !== 'string' || newDisplayName.trim().length === 0 || newDisplayName.length > 32) {
    return res.status(400).json({ message: 'Display name must be 1-32 characters' });
  }

  let sql = 'UPDATE users SET display_name = ?';
  let params = [newDisplayName.trim()];

  if (newPassword && newPassword.length > 0) {
    if (typeof newPassword !== 'string' || newPassword.length < 6 || newPassword.length > 128) {
      return res.status(400).json({ message: 'Password must be 6-128 characters' });
    }
    sql += ', password = ?';
    params.push(hashPassword(newPassword));
  }

  sql += ' WHERE id = ?';
  params.push(userId);

  db.run(sql, params, function(err) {
    if (err) {
      return res.status(500).json({ message: 'Error updating profile' });
    }
    res.json({ message: 'Profile updated successfully', display_name: newDisplayName.trim() });
  });
};

const uploadPfp = (req, res) => {
  const userId = req.user && req.user.id;
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
  const user_id = req.user && req.user.id;
  if (user_id) {
    setOffline(user_id);
    console.log(`User ${user_id} logged out and marked offline.`);
  }
  res.json({ ok: true });
};

module.exports = { register, login, updateProfile, uploadPfp, logout };
