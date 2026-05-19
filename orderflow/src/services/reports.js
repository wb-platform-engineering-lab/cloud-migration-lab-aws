'use strict';

const PDFDocument = require('pdfkit');
const { Order, Product, Customer } = require('../models');

// Generates a daily sales PDF report.
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 7):
// This runs inside the HTTP request handler on the main Node.js thread.
// PDFKit renders synchronously — while it runs, the event loop is blocked
// and all other incoming requests queue up behind it.
// On a dataset of ~500 orders this takes 3–5 seconds of pure CPU time.
async function generateDailyReport() {
  // Step 1: fetch all data (async — does not block the event loop)
  const orders = await Order.findAll({
    include: [
      { model: Customer, as: 'customer', attributes: ['id', 'name', 'email'] },
      { model: Product,  as: 'product',  attributes: ['id', 'name', 'price'] },
    ],
    order: [['createdAt', 'DESC']],
  });

  // Step 2: aggregate (synchronous CPU work — BLOCKS the event loop)
  const stats = computeStats(orders);

  // Step 3: render the PDF (synchronous — BLOCKS the event loop)
  const pdfBuffer = renderPDF(stats, orders);

  return { stats, pdfBuffer };
}

// ─── Synchronous CPU work ────────────────────────────────────────────────────

function computeStats(orders) {
  const stats = {
    totalOrders:   orders.length,
    totalRevenue:  0,
    byProduct:     {},
    byStatus:      {},
    topCustomers:  {},
  };

  for (const order of orders) {
    const revenue = Number(order.total);
    stats.totalRevenue += revenue;

    // Aggregate by product
    const productName = order.product?.name ?? 'Unknown';
    if (!stats.byProduct[productName]) {
      stats.byProduct[productName] = { orders: 0, revenue: 0, units: 0 };
    }
    stats.byProduct[productName].orders  += 1;
    stats.byProduct[productName].revenue += revenue;
    stats.byProduct[productName].units   += order.quantity;

    // Aggregate by status
    stats.byStatus[order.status] = (stats.byStatus[order.status] || 0) + 1;

    // Aggregate by customer
    const customerName = order.customer?.name ?? 'Unknown';
    if (!stats.topCustomers[customerName]) {
      stats.topCustomers[customerName] = { orders: 0, revenue: 0 };
    }
    stats.topCustomers[customerName].orders  += 1;
    stats.topCustomers[customerName].revenue += revenue;

    // Intentional extra CPU work so this is measurably slow.
    // Simulates the kind of in-process aggregation a real report might do
    // across a large dataset.
    burnCpu(500);
  }

  return stats;
}

// Spins the CPU for `iterations` cycles.
// This is the root cause of the latency spike observed in Phase 0 Challenge 4.
function burnCpu(iterations) {
  let x = 0;
  for (let i = 0; i < iterations * 1000; i++) {
    x = Math.sqrt(i) * Math.sin(i);
  }
  return x;
}

function renderPDF(stats, orders) {
  const doc = new PDFDocument({ margin: 50 });
  const buffers = [];

  doc.on('data', (chunk) => buffers.push(chunk));

  // Title
  doc.fontSize(24).font('Helvetica-Bold').text('OrderFlow — Daily Sales Report', { align: 'center' });
  doc.moveDown();
  doc.fontSize(12).font('Helvetica').text(`Generated: ${new Date().toUTCString()}`, { align: 'center' });
  doc.moveDown(2);

  // Summary
  doc.fontSize(16).font('Helvetica-Bold').text('Summary');
  doc.moveDown(0.5);
  doc.fontSize(12).font('Helvetica');
  doc.text(`Total orders:   ${stats.totalOrders}`);
  doc.text(`Total revenue:  $${stats.totalRevenue.toFixed(2)}`);
  doc.moveDown();

  // By status
  doc.fontSize(16).font('Helvetica-Bold').text('Orders by Status');
  doc.moveDown(0.5);
  doc.fontSize(12).font('Helvetica');
  for (const [status, count] of Object.entries(stats.byStatus)) {
    doc.text(`  ${status}: ${count}`);
  }
  doc.moveDown();

  // By product
  doc.fontSize(16).font('Helvetica-Bold').text('Revenue by Product');
  doc.moveDown(0.5);
  doc.fontSize(12).font('Helvetica');
  const sortedProducts = Object.entries(stats.byProduct)
    .sort(([, a], [, b]) => b.revenue - a.revenue);
  for (const [name, data] of sortedProducts) {
    doc.text(`  ${name}: ${data.orders} orders, ${data.units} units, $${data.revenue.toFixed(2)}`);
  }
  doc.moveDown();

  // Recent orders table
  doc.addPage();
  doc.fontSize(16).font('Helvetica-Bold').text('Recent Orders (last 50)');
  doc.moveDown(0.5);
  doc.fontSize(10).font('Helvetica');

  const recent = orders.slice(0, 50);
  for (const order of recent) {
    doc.text(
      `#${order.id}  ${order.customer?.name ?? '-'}  ${order.product?.name ?? '-'}  ` +
      `qty:${order.quantity}  $${Number(order.total).toFixed(2)}  ${order.status}`
    );
  }

  doc.end();
  return Buffer.concat(buffers);
}

module.exports = { generateDailyReport, burnCpu };
