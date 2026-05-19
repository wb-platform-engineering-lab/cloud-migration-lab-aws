// Mock the DB models so reports.js can be imported without a live database
jest.mock('../models', () => ({
  Order:    { findAll: jest.fn().mockResolvedValue([]) },
  Product:  {},
  Customer: {},
}));

const { burnCpu } = require('../services/reports');

describe('burnCpu', () => {
  it('returns a number', () => {
    const result = burnCpu(1);
    expect(typeof result).toBe('number');
  });

  it('takes measurably longer with more iterations', () => {
    const start1 = Date.now();
    burnCpu(10);
    const t1 = Date.now() - start1;

    const start2 = Date.now();
    burnCpu(100);
    const t2 = Date.now() - start2;

    expect(t2).toBeGreaterThan(t1);
  });
});
