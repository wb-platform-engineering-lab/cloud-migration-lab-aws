'use strict';

require('dotenv').config();

const express      = require('express');
const session      = require('express-session');
const morgan       = require('morgan');
const { createClient } = require('redis');
const RedisStore   = require('connect-redis').default;

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

const redisClient = createClient({ url: process.env.REDIS_URL });
redisClient.connect();

app.use(session({
  store: new RedisStore({ client: redisClient }),
  secret: process.env.SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: process.env.NODE_ENV === 'production' }
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
    });
  } catch (err) {
    console.error('[app] Failed to start:', err.message);
    process.exit(1);
  }
}

start();

module.exports = app;
