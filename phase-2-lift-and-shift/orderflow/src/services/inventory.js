'use strict';

const { Product } = require('../models');

// Deducts stock for a given product after an order is placed.
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 6):
// This runs synchronously inside the HTTP request handler.
// The customer waits for the inventory update to complete before
// receiving their order confirmation.
async function deductStock(productId, quantity) {
  const product = await Product.findByPk(productId);

  if (!product) {
    throw new Error(`Product ${productId} not found`);
  }

  if (product.stock < quantity) {
    throw new Error(`Insufficient stock for product ${productId}`);
  }

  await product.decrement('stock', { by: quantity });

  console.log(`[inventory] Product ${productId} stock reduced by ${quantity} (new stock: ${product.stock - quantity})`);
}

// Returns current stock level for a product.
async function getStock(productId) {
  const product = await Product.findByPk(productId, { attributes: ['id', 'name', 'stock'] });
  if (!product) throw new Error(`Product ${productId} not found`);
  return product.stock;
}

module.exports = { deductStock, getStock };
