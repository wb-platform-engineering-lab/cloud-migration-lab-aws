'use strict';

const { Router } = require('express');
const { Order, Product, Customer } = require('../models');
const { requireAuth } = require('../middleware/auth');
const emailService = require('../services/email');
const inventoryService = require('../services/inventory');
const reportService = require('../services/reports');

const router = Router();

// GET /orders
router.get('/', requireAuth, async (req, res) => {
  try {
    const orders = await Order.findAll({
      where: { customerId: req.session.customerId },
      include: [{ model: Product, as: 'product', attributes: ['id', 'name', 'price'] }],
      order: [['createdAt', 'DESC']],
    });
    return res.json(orders);
  } catch (err) {
    console.error('[orders] list error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch orders' });
  }
});

// GET /orders/:id
router.get('/:id', requireAuth, async (req, res) => {
  try {
    const order = await Order.findOne({
      where: { id: req.params.id, customerId: req.session.customerId },
      include: [
        { model: Product,  as: 'product',  attributes: ['id', 'name', 'price'] },
        { model: Customer, as: 'customer', attributes: ['id', 'name', 'email'] },
      ],
    });
    if (!order) return res.status(404).json({ error: 'Order not found' });
    return res.json(order);
  } catch (err) {
    console.error('[orders] get error:', err.message);
    return res.status(500).json({ error: 'Failed to fetch order' });
  }
});

// POST /orders
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 6):
// All downstream work — inventory deduction, confirmation email, warehouse
// notification — runs synchronously inside this HTTP request handler.
//
// Consequences:
//   - If email is slow, the customer waits.
//   - If inventory service throws, the order fails even though payment succeeded.
//   - Response time = DB write + inventory update + email send (sequential).
router.post('/', requireAuth, async (req, res) => {
  try {
    const { productId, quantity } = req.body;

    if (!productId || !quantity || quantity < 1) {
      return res.status(400).json({ error: 'productId and quantity (≥1) are required' });
    }

    // 1. Fetch the product
    const product = await Product.findByPk(productId);
    if (!product) return res.status(404).json({ error: 'Product not found' });

    if (product.stock < quantity) {
      return res.status(409).json({ error: `Insufficient stock (available: ${product.stock})` });
    }

    const total = (Number(product.price) * quantity).toFixed(2);

    // 2. Create the order record
    const order = await Order.create({
      customerId: req.session.customerId,
      productId,
      quantity,
      total,
      status: 'confirmed',
    });

    // 3. Deduct inventory — synchronous, inside the request
    await inventoryService.deductStock(productId, quantity);

    // 4. Send confirmation email — synchronous, inside the request
    const customer = await Customer.findByPk(req.session.customerId);
    await emailService.sendOrderConfirmation(customer, order, product);

    // 5. Simulate warehouse notification — synchronous, inside the request
    console.log(`[warehouse] Notify: order #${order.id}, product ${product.name}, qty ${quantity}`);

    return res.status(201).json({
      id:        order.id,
      status:    order.status,
      productId: order.productId,
      quantity:  order.quantity,
      total:     Number(order.total),
      createdAt: order.createdAt,
    });
  } catch (err) {
    console.error('[orders] create error:', err.message);
    return res.status(500).json({ error: err.message || 'Failed to create order' });
  }
});

// PUT /orders/:id/cancel
router.put('/:id/cancel', requireAuth, async (req, res) => {
  try {
    const order = await Order.findOne({
      where: { id: req.params.id, customerId: req.session.customerId },
    });
    if (!order) return res.status(404).json({ error: 'Order not found' });

    if (!['pending', 'confirmed'].includes(order.status)) {
      return res.status(409).json({ error: `Cannot cancel order with status "${order.status}"` });
    }

    await order.update({ status: 'cancelled' });

    // Restore stock
    await Product.increment('stock', { by: order.quantity, where: { id: order.productId } });

    return res.json({ id: order.id, status: order.status });
  } catch (err) {
    console.error('[orders] cancel error:', err.message);
    return res.status(500).json({ error: 'Failed to cancel order' });
  }
});

// GET /reports/daily
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 7):
// Report generation runs on the main thread, synchronously.
// PDFKit renders in-process. The event loop is blocked for the entire duration.
// All other requests queue up and wait.
router.get('/reports/daily', requireAuth, async (req, res) => {
  try {
    console.log('[reports] Starting daily report generation...');
    const start = Date.now();

    const { stats, pdfBuffer } = await reportService.generateDailyReport();

    const elapsed = ((Date.now() - start) / 1000).toFixed(2);
    console.log(`[reports] Daily report generated in ${elapsed}s — ${pdfBuffer.length} bytes`);

    res.set({
      'Content-Type':        'application/pdf',
      'Content-Disposition': `attachment; filename="orderflow-daily-${new Date().toISOString().slice(0, 10)}.pdf"`,
      'Content-Length':      pdfBuffer.length,
      'X-Report-Duration':   `${elapsed}s`,
      'X-Total-Orders':      stats.totalOrders,
      'X-Total-Revenue':     stats.totalRevenue.toFixed(2),
    });

    return res.send(pdfBuffer);
  } catch (err) {
    console.error('[reports] generation error:', err.message);
    return res.status(500).json({ error: 'Failed to generate report' });
  }
});

module.exports = router;
