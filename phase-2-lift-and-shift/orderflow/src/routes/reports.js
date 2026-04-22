'use strict';

const { Router } = require('express');
const { requireAuth } = require('../middleware/auth');
const reportService = require('../services/reports');

const router = Router();

// GET /reports/daily
//
// INTENTIONAL DESIGN FLAW (Phase 0 → fixed in Phase 7):
// Report generation runs on the main thread, synchronously.
// PDFKit renders in-process. The event loop is blocked for the entire duration.
// All other requests queue up and wait.
router.get('/daily', requireAuth, async (req, res) => {
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
