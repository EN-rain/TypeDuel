const jwt = require('jsonwebtoken');
const { getJwtSecret } = require('../utils/jwtSecret');

const authMiddleware = (req, res, next) => {
  const authHeader = req.header('Authorization');
  const token = authHeader && authHeader.split(' ')[1];

  if (!token) {
    return res.status(401).json({ message: 'No token, authorization denied' });
  }

  try {
    const decoded = jwt.verify(token, getJwtSecret());
    req.user = decoded;
    next();
  } catch (err) {
    console.error('JWT Verify Error:', err.message, 'Token:', token);
    res.status(401).json({ message: 'Token is not valid' });
  }
};

module.exports = authMiddleware;
