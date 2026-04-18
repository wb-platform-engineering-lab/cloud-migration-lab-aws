'use strict';

function requireAuth(req, res, next) {
  if (!req.session.customerId) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  next();
}

module.exports = { requireAuth };
