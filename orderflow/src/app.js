'use strict';

require('dotenv').config();

const express = require('express');
const session = require('express-session');
const morgan  = require('morgan');

const { sequelize } = require('./models');

const authRouter      = require('./routes/auth');
const customersRouter = require('./routes/customers');
const productsRouter  = require('./routes/products');
const ordersRouter    = require('./routes/orders');
const reportsRouter   = require('./routes/reports');

const app  = express();
const PORT = process.env.PORT || 3000;

// ─── Middleware ───────────────────────────────────────────────────────────────

app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(morgan(process.env.NODE_ENV === 'production' ? 'combined' : 'dev'));
app.use(express.static('public'));

// Session configuration
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 2 + Phase 8):
// Using the default MemoryStore — sessions live in process memory only.
// This means:
//   1. All sessions are lost when the process restarts.
//   2. Two instances behind a load balancer cannot share sessions.
//      A user logged in on instance A will be logged out if their next
//      request is routed to instance B.
//
// In Phase 2 this is fixed by switching to ElastiCache Redis as the store.
// In Phase 8 this is replaced entirely by Cognito JWT tokens.
app.use(session({
  secret:            process.env.SESSION_SECRET || 'dev-secret-change-me',
  resave:            false,
  saveUninitialized: false,
  cookie: {
    secure:   process.env.NODE_ENV === 'production',
    httpOnly: true,
    maxAge:   24 * 60 * 60 * 1000, // 24 hours
  },
}));

// ─── Routes ──────────────────────────────────────────────────────────────────

app.use('/auth',      authRouter);
app.use('/customers', customersRouter);
app.use('/products',  productsRouter);
app.use('/orders',    ordersRouter);
app.use('/reports',   reportsRouter);

// Health check
// Used by the ALB health check in Phase 2 and ECS health check in Phase 3.
app.get('/health', async (req, res) => {
  const health = { status: 'ok', db: 'unknown', uptime: process.uptime() };

  try {
    await sequelize.authenticate();
    health.db = 'connected';
  } catch {
    health.db     = 'disconnected';
    health.status = 'degraded';
  }

  const statusCode = health.status === 'ok' ? 200 : 503;
  return res.status(statusCode).json(health);
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: `Cannot ${req.method} ${req.path}` });
});

// Global error handler
app.use((err, req, res, _next) => {
  console.error('[error]', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

// ─── Boot ─────────────────────────────────────────────────────────────────────

async function start() {
  try {
    await sequelize.authenticate();
    console.log('[db] Connected to PostgreSQL');

    app.listen(PORT, () => {
      console.log(`[app] OrderFlow listening on port ${PORT}`);
      console.log(`[app] Environment: ${process.env.NODE_ENV || 'development'}`);
      console.log(`[app] Session store: MemoryStore (in-process) ← Phase 0 intentional flaw`);
    });
  } catch (err) {
    console.error('[app] Failed to start:', err.message);
    process.exit(1);
  }
}

start();

module.exports = app;
