# Phase 0 — Meet the Monolith

> **AWS services introduced:** None — local Docker only | **Cost:** $0

---

## The problem

Before you can migrate anything, you must understand what you are migrating. The first failure mode in cloud migrations is moving a system nobody fully understands. You end up with the same problems, just hosted somewhere more expensive.

## What you will do

Run OrderFlow locally using Docker Compose. Break it intentionally. Understand its failure modes before you carry them into AWS.

```bash
git clone https://github.com/your-org/cloud-migration-lab-aws
cd cloud-migration-lab-aws/orderflow
docker compose up
```

The local stack runs:
- `app` — the Node.js monolith on port 3000
- `postgres` — PostgreSQL 15
- `redis` — for sessions (you will learn why this matters in Phase 2)

## Challenges

1. Run the monolith and place a test order via the API
2. Kill the app container mid-request — observe what happens to in-flight orders
3. Scale the app to 2 containers — log in on one, make a request on the other — observe the session problem
4. Generate a report while processing orders — observe request latency spike
5. Run `docker stats` and identify which operations use the most CPU and memory

## What you will observe

- Sessions stored in process memory break under horizontal scale
- Report generation blocks the Node.js event loop and delays order responses by 3–5 seconds
- There is no separation between stateless logic (order routing) and stateful storage (database, sessions, files)
- A single crash loses all in-flight state

These observations directly motivate the architecture choices in every subsequent phase.

## Outcome

A running local OrderFlow instance and a written list of the top 5 problems you need to solve before this can run reliably on AWS. Keep this list — every phase resolves one of them.

---

[Back to main README](../README.md) | [Next: Phase 1 — AWS Foundations](../phase-1-foundations/README.md)
