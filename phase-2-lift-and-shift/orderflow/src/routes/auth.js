'use strict';

const { Router } = require('express');
const bcrypt = require('bcryptjs');
const { Customer } = require('../models');

const router = Router();

// POST /auth/register
router.post('/register', async (req, res) => {
  try {
    const { name, email, password } = req.body;

    if (!name || !email || !password) {
      return res.status(400).json({ error: 'name, email, and password are required' });
    }

    const existing = await Customer.findOne({ where: { email } });
    if (existing) {
      return res.status(409).json({ error: 'Email already registered' });
    }

    const hashed = await bcrypt.hash(password, 10);
    const customer = await Customer.create({ name, email, password: hashed });

    req.session.customerId = customer.id;
    req.session.customerName = customer.name;

    return res.status(201).json({
      id:    customer.id,
      name:  customer.name,
      email: customer.email,
    });
  } catch (err) {
    console.error('[auth] register error:', err.message);
    return res.status(500).json({ error: 'Registration failed' });
  }
});

// POST /auth/login
router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({ error: 'email and password are required' });
    }

    const customer = await Customer.findOne({ where: { email } });
    if (!customer) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const valid = await bcrypt.compare(password, customer.password);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    // INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 2 + Phase 8):
    // Session is stored in the MemoryStore (process memory) by default.
    // If this process restarts, all sessions are lost.
    // If two instances run behind a load balancer, sessions are not shared.
    req.session.customerId = customer.id;
    req.session.customerName = customer.name;

    return res.json({
      id:    customer.id,
      name:  customer.name,
      email: customer.email,
    });
  } catch (err) {
    console.error('[auth] login error:', err.message);
    return res.status(500).json({ error: 'Login failed' });
  }
});

// POST /auth/logout
router.post('/logout', (req, res) => {
  req.session.destroy((err) => {
    if (err) {
      return res.status(500).json({ error: 'Logout failed' });
    }
    res.clearCookie('connect.sid');
    return res.json({ message: 'Logged out' });
  });
});

// GET /auth/me
router.get('/me', (req, res) => {
  if (!req.session.customerId) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  return res.json({
    id:   req.session.customerId,
    name: req.session.customerName,
  });
});

module.exports = router;
