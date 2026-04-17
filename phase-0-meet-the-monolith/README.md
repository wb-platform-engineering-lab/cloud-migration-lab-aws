# Phase 0 — Meet the Monolith

> **AWS services introduced:** None — local Docker only | **Daily cost:** $0

## Objective

Before migrating anything you must understand what you are migrating. Run OrderFlow locally, break it intentionally, and document its failure modes before carrying them into AWS.

## What you will do

```bash
cd ../orderflow
docker compose up
```

The local stack:

| Container | Purpose | Port |
|---|---|---|
| `app` | Node.js/Express monolith | 3000 |
| `postgres` | PostgreSQL 15 | 5432 |
| `redis` | Session store | 6379 |

## Challenges

1. Run the monolith and place a test order via the API
2. Kill the `app` container mid-request — observe what happens to in-flight orders
3. Scale to 2 app containers — log in on one, make a request through the other — observe the session problem
4. Generate a report while processing orders — observe request latency spike
5. Run `docker stats` and identify which operations consume the most CPU and memory

## What to observe

- Sessions stored in process memory break under horizontal scale
- Report generation blocks the Node.js event loop and delays order responses by 3–5 seconds
- A single crash loses all in-flight state

## Outcome

A running local OrderFlow instance and a written list of the top 5 problems to solve before this system can run reliably on AWS. Keep this list — every subsequent phase resolves one of them.

---

[Back to main README](../README.md)
