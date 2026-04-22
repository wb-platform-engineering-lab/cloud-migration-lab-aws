'use strict';

require('dotenv').config();

const { sequelize } = require('./models');

async function migrate() {
  try {
    console.log('[migrate] Connecting to database...');
    await sequelize.authenticate();
    console.log('[migrate] Connected');

    console.log('[migrate] Syncing schema...');
    // alter: true — adds missing columns without dropping existing ones.
    // Use force: true to drop and recreate all tables (destructive).
    await sequelize.sync({ alter: true });

    console.log('[migrate] Schema up to date');
    process.exit(0);
  } catch (err) {
    console.error('[migrate] Failed:', err.message);
    process.exit(1);
  }
}

migrate();
