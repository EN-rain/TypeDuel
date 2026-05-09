const crypto = require('crypto');

const developmentSecret = crypto.randomBytes(32).toString('hex');

function getJwtSecret() {
  if (process.env.JWT_SECRET) return process.env.JWT_SECRET;
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET must be configured in production');
  }
  return developmentSecret;
}

module.exports = { getJwtSecret };
