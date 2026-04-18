'use strict';

const { Router } = require('express');
const { Product } = require('../models');
const { requireAuth } = require('../middleware/auth');

const router = Router();

// GET /products
router.get('/', async (req, res) => {
  try {
    const products = await Product.findAll({ order: [['name', 'ASC']] });
    return res.json(products);
  } catch (err) {
    console.error('[products] list error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch products' });
  }
});

// GET /products/:id
router.get('/:id', async (req, res) => {
  try {
    const product = await Product.findByPk(req.params.id);
    if (!product) return res.status(404).json({ error: 'Product not found' });
    return res.json(product);
  } catch (err) {
    console.error('[products] get error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch product' });
  }
});

// POST /products
router.post('/', requireAuth, async (req, res) => {
  try {
    const { name, description, price, stock } = req.body;

    if (!name || price === undefined) {
      return res.status(400).json({ error: 'name and price are required' });
    }

    const product = await Product.create({ name, description, price, stock: stock ?? 0 });
    return res.status(201).json(product);
  } catch (err) {
    console.error('[products] create error:', err.message);
    return res.status(500).json({ error: 'Failed to create product' });
  }
});

// PUT /products/:id
router.put('/:id', requireAuth, async (req, res) => {
  try {
    const product = await Product.findByPk(req.params.id);
    if (!product) return res.status(404).json({ error: 'Product not found' });

    const { name, description, price, stock } = req.body;
    if (name        !== undefined) product.name        = name;
    if (description !== undefined) product.description = description;
    if (price       !== undefined) product.price       = price;
    if (stock       !== undefined) product.stock       = stock;

    await product.save();
    return res.json(product);
  } catch (err) {
    console.error('[products] update error:', err.message);
    return res.status(500).json({ error: 'Failed to update product' });
  }
});

// DELETE /products/:id
router.delete('/:id', requireAuth, async (req, res) => {
  try {
    const product = await Product.findByPk(req.params.id);
    if (!product) return res.status(404).json({ error: 'Product not found' });
    await product.destroy();
    return res.status(204).send();
  } catch (err) {
    console.error('[products] delete error:', err.message);
    return res.status(500).json({ error: 'Failed to delete product' });
  }
});

module.exports = router;
