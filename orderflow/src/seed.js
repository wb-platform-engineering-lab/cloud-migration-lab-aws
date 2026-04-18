'use strict';

require('dotenv').config();

const bcrypt = require('bcryptjs');
const { sequelize, Customer, Product, Order } = require('./models');

async function seed() {
  try {
    await sequelize.authenticate();
    await sequelize.sync({ alter: true });

    console.log('[seed] Creating customers...');
    const password = await bcrypt.hash('password123', 10);

    const [alice] = await Customer.findOrCreate({
      where: { email: 'alice@example.com' },
      defaults: { name: 'Alice Martin', password },
    });

    const [bob] = await Customer.findOrCreate({
      where: { email: 'bob@example.com' },
      defaults: { name: 'Bob Smith', password },
    });

    console.log('[seed] Creating products...');
    const products = await Promise.all([
      Product.findOrCreate({ where: { name: 'Widget A' },   defaults: { description: 'Standard widget, blue',   price: 29.99,  stock: 200 } }),
      Product.findOrCreate({ where: { name: 'Widget B' },   defaults: { description: 'Premium widget, red',     price: 49.99,  stock: 150 } }),
      Product.findOrCreate({ where: { name: 'Gadget Pro' }, defaults: { description: 'Professional gadget kit', price: 149.99, stock: 75  } }),
      Product.findOrCreate({ where: { name: 'Gizmo X' },   defaults: { description: 'Compact gizmo device',    price: 89.99,  stock: 120 } }),
      Product.findOrCreate({ where: { name: 'Doohickey' }, defaults: { description: 'Multi-purpose doohickey', price: 19.99,  stock: 300 } }),
    ]);

    const flatProducts = products.map(([p]) => p);

    console.log('[seed] Creating sample orders...');
    const statuses = ['confirmed', 'shipped', 'delivered'];

    for (let i = 0; i < 30; i++) {
      const customer  = i % 2 === 0 ? alice : bob;
      const product   = flatProducts[i % flatProducts.length];
      const quantity  = Math.floor(Math.random() * 4) + 1;
      const total     = (Number(product.price) * quantity).toFixed(2);
      const status    = statuses[i % statuses.length];

      await Order.create({ customerId: customer.id, productId: product.id, quantity, total, status });
    }

    console.log('[seed] Done');
    console.log('[seed] Login credentials:');
    console.log('  alice@example.com / password123');
    console.log('  bob@example.com   / password123');
    process.exit(0);
  } catch (err) {
    console.error('[seed] Failed:', err.message);
    process.exit(1);
  }
}

seed();
