'use strict';

const nodemailer = require('nodemailer');

// In development, log emails instead of sending them.
// In production, configure SMTP credentials via environment variables.
function createTransport() {
  if (process.env.NODE_ENV !== 'production' || !process.env.SMTP_HOST) {
    return nodemailer.createTransport({ jsonTransport: true });
  }

  return nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: parseInt(process.env.SMTP_PORT, 10) || 587,
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS,
    },
  });
}

const transporter = createTransport();

// Sends an order confirmation email.
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 6):
// This runs synchronously inside the HTTP request handler.
// If the email server is slow or down, the customer waits — or the order fails.
async function sendOrderConfirmation(customer, order, product) {
  const message = {
    from: process.env.EMAIL_FROM || 'noreply@orderflow.com',
    to: customer.email,
    subject: `Order #${order.id} confirmed`,
    text: [
      `Hi ${customer.name},`,
      '',
      `Your order has been confirmed.`,
      '',
      `  Product:  ${product.name}`,
      `  Quantity: ${order.quantity}`,
      `  Total:    $${Number(order.total).toFixed(2)}`,
      '',
      'Thank you for shopping with OrderFlow.',
    ].join('\n'),
  };

  const result = await transporter.sendMail(message);

  if (process.env.NODE_ENV !== 'production') {
    console.log(`[email] Order #${order.id} confirmation → ${customer.email}`);
  }

  return result;
}

module.exports = { sendOrderConfirmation };
