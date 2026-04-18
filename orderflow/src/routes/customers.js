'use strict';

const { Router } = require('express');
const bcrypt = require('bcryptjs');
const { Customer, Order } = require('../models');
const { requireAuth } = require('../middleware/auth');

const router = Router();

// GET /customers — list all customers (admin use)
router.get('/', requireAuth, async (req, res) => {
  try {
    const customers = await Customer.findAll({
      attributes: ['id', 'name', 'email', 'createdAt'],
      order: [['createdAt', 'DESC']],
    });
    return res.json(customers);
  } catch (err) {
    console.error('[customers] list error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch customers' });
  }
});

// GET /customers/:id
router.get('/:id', requireAuth, async (req, res) => {
  try {
    const customer = await Customer.findByPk(req.params.id, {
      attributes: ['id', 'name', 'email', 'createdAt'],
    });
    if (!customer) return res.status(404).json({ error: 'Customer not found' });
    return res.json(customer);
  } catch (err) {
    console.error('[customers] get error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch customer' });
  }
});

// PUT /customers/:id — update name or password
router.put('/:id', requireAuth, async (req, res) => {
  try {
    if (req.session.customerId !== parseInt(req.params.id, 10)) {
      return res.status(403).json({ error: 'You can only update your own profile' });
    }

    const customer = await Customer.findByPk(req.params.id);
    if (!customer) return res.status(404).json({ error: 'Customer not found' });

    const { name, password } = req.body;
    if (name) customer.name = name;
    if (password) customer.password = await bcrypt.hash(password, 10);

    await customer.save();
    return res.json({ id: customer.id, name: customer.name, email: customer.email });
  } catch (err) {
    console.error('[customers] update error:', err.message);
    return res.status(500).json({ error: 'Failed to update customer' });
  }
});

// GET /customers/:id/orders — orders belonging to a customer
router.get('/:id/orders', requireAuth, async (req, res) => {
  try {
    const orders = await Order.findAll({
      where: { customerId: req.params.id },
      order: [['createdAt', 'DESC']],
    });
    return res.json(orders);
  } catch (err) {
    console.error('[customers] orders error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch orders' });
  }
});

module.exports = router;
