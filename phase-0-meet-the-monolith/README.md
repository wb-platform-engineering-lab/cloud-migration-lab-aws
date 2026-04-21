# Phase 0 — Meet the Monolith

> **AWS services introduced:** None — local Docker only | **Cost:** $0

---

## The problem

Before you can migrate anything, you must understand what you are migrating. The first failure mode in cloud migrations is moving a system nobody fully understands. You end up with the same problems, just hosted somewhere more expensive.

## What you will do

Run OrderFlow locally using Docker Compose. Break it intentionally. Understand its failure modes before you carry them into AWS.

The local stack runs:
- `app` — the Node.js monolith on port 3000
- `postgres` — PostgreSQL 15
- `redis` — for sessions (you will learn why this matters in Phase 2)

---

## Challenge 1 — Run the monolith and place a test order

### Step 1: Clone the repository and start the stack

```bash
git clone https://github.com/wb-platform-engineering-lab/cloud-migration-lab-aws
cd cloud-migration-lab-aws/orderflow
docker compose up
```

Wait until you see all three services ready:
```
app       | Server listening on port 3000
postgres  | database system is ready to accept connections
redis     | Ready to accept connections
```

### Step 2: Run the database migration

The app does not auto-create tables on startup. Run the migration once after the first `docker compose up`:

```bash
docker compose exec app node src/migrate.js
```

Expected:
```
[migrate] Connecting to database...
[migrate] Connected
[migrate] Syncing schema...
[migrate] Schema up to date
```

### Step 3: Verify the app is healthy

```bash
curl http://localhost:3000/health
```

Expected response:
```json
{ "status": "ok", "db": "connected" }
```

### Step 4: Register a user

```bash
curl -s -X POST http://localhost:3000/auth/register \
  -H "Content-Type: application/json" \
  -d '{"name": "Test User", "email": "test@orderflow.com", "password": "password123"}' | jq
```

Expected response:
```json
{
  "id": 1,
  "name": "Test User",
  "email": "test@orderflow.com"
}
```

### Step 5: Log in and save the session cookie

```bash
curl -s -c cookies.txt -X POST http://localhost:3000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "test@orderflow.com", "password": "password123"}' | jq
```

The `-c cookies.txt` flag saves the session cookie to a file for reuse.

### Step 6: Create a product

```bash
curl -s -b cookies.txt -X POST http://localhost:3000/products \
  -H "Content-Type: application/json" \
  -d '{"name": "Widget A", "price": 29.99, "stock": 100}' | jq
```

Note the `id` field in the response — you will need it in the next step.

### Step 7: Place an order

```bash
curl -s -b cookies.txt -X POST http://localhost:3000/orders \
  -H "Content-Type: application/json" \
  -d '{"productId": 1, "quantity": 2}' | jq
```

Expected response:
```json
{
  "id": 1,
  "status": "confirmed",
  "productId": 1,
  "quantity": 2,
  "total": 59.98
}
```

### Step 8: List your orders

```bash
curl -s -b cookies.txt http://localhost:3000/orders | jq
```

**What you have confirmed:** the monolith can accept requests, write to PostgreSQL, and return responses. Everything works — for now.

---

## Challenge 2 — Kill the app container mid-request and observe in-flight orders

### Step 1: Start a slow request in the background

The report endpoint is CPU-intensive and takes several seconds. Use it to simulate a long-running in-flight request.

```bash
curl -s -b cookies.txt http://localhost:3000/reports/daily &
```

### Step 2: Immediately kill the app container

While the request is still running (within 1–2 seconds of starting it), kill the container:

```bash
docker compose kill app
```

### Step 3: Observe the result

Switch back to the terminal running the `curl` command. You will see one of:
- An empty response
- `curl: (52) Empty reply from server`
- `curl: (56) Recv failure: Connection reset by peer`

The request was dropped. No error was returned to the client. The order or report was never completed.

### Step 4: Check the database for partial state

```bash
docker compose exec postgres psql -U orderflow -c "SELECT * FROM orders ORDER BY created_at DESC LIMIT 5;"
```

Depending on where in the transaction the kill happened, you may see a partial record or no record at all. There is no way to know from the client side whether the operation succeeded.

### Step 5: Restart the app

```bash
docker compose up app
```

**What you have observed:** a single process crash silently drops in-flight requests. There is no graceful shutdown, no retry, no client notification. Any order that was being written when the crash occurred is either lost or left in an unknown state.

---

## Challenge 3 — Scale to 2 containers and observe the session problem

### Step 1: Update docker-compose to allow multiple app replicas

Open `docker-compose.yml` and remove the fixed `container_name` from the `app` service (fixed names block scaling), then remove the fixed port mapping and replace with a range:

```yaml
app:
  build: .
  # container_name: app   ← remove this line
  ports:
    - "3000-3001:3000"
  environment:
    - DATABASE_URL=postgres://orderflow:orderflow@postgres:5432/orderflow
    - REDIS_URL=redis://redis:6379
    - SESSION_SECRET=dev-secret
  depends_on:
    - postgres
    - redis
```

### Step 2: Scale the app service to 2 replicas

```bash
docker compose up --scale app=2 -d
```

Verify both containers are running:
```bash
docker compose ps
```

You should see two `app` containers: one on port 3000, one on port 3001.

### Step 3: Log in through the first container

```bash
curl -s -c cookies_3000.txt -X POST http://localhost:3000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "test@orderflow.com", "password": "password123"}' | jq
```

### Step 4: Make an authenticated request through the second container

```bash
curl -s -b cookies_3000.txt http://localhost:3001/orders | jq
```

**Expected result:** `401 Unauthorized` or an empty order list — even though you are logged in.

This is the session problem: the session was written to the memory of the first container. The second container has no knowledge of it. From the user's perspective, they are randomly logged out depending on which server handles their request.

### Step 5: Confirm the root cause

```bash
# This works — same container that created the session
curl -s -b cookies_3000.txt http://localhost:3000/orders | jq

# This fails — different container, no shared session store
curl -s -b cookies_3000.txt http://localhost:3001/orders | jq
```

**What you have observed:** in-memory sessions cannot be shared across processes. This is the exact problem that ElastiCache Redis solves in Phase 2.

---

## Challenge 4 — Generate a report while processing orders and observe latency

### Step 1: Start a continuous stream of order requests

Open a new terminal and run a loop that places orders every 0.5 seconds:

```bash
while true; do
  curl -s -b cookies.txt -X POST http://localhost:3000/orders \
    -H "Content-Type: application/json" \
    -d '{"productId": 1, "quantity": 1}' \
    -w "\nTime: %{time_total}s\n" | grep -E "(status|Time)"
  sleep 0.5
done
```

Observe the response times — they should be consistently under 100ms.

### Step 2: Trigger the report generation in a separate terminal

```bash
time curl -s -b cookies.txt http://localhost:3000/reports/daily -o /dev/null
```

### Step 3: Watch the order response times during report generation

Go back to your first terminal. While the report is generating, you will see order response times spike to 3–5 seconds or more.

```
{"status":"confirmed",...}
Time: 0.045s
{"status":"confirmed",...}
Time: 0.052s
{"status":"confirmed",...}
Time: 3.847s    ← report running
{"status":"confirmed",...}
Time: 4.102s    ← report still running
{"status":"confirmed",...}
Time: 0.048s    ← report finished
```

### Step 4: Explain why this happens

Node.js runs on a single thread. The report generator is CPU-intensive: it queries the database, aggregates data, and renders a PDF. While it is doing this, the event loop is blocked and cannot process other incoming requests. Every API call waits in the queue.

**What you have observed:** a single CPU-bound operation degrades the entire API. This is the exact problem that Lambda + EventBridge Scheduler solves in Phase 7.

---

## Challenge 5 — Run docker stats and identify resource usage

### Step 1: Start docker stats

```bash
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

You will see a live table refreshing every second:

```
NAME        CPU %     MEM USAGE / LIMIT   MEM %
app         0.5%      85MiB / 7.77GiB     1.07%
postgres    0.2%      32MiB / 7.77GiB     0.40%
redis       0.1%      8MiB / 7.77GiB      0.10%
```

### Step 2: Trigger a report and watch CPU

In another terminal, trigger the report:

```bash
curl -s -b cookies.txt http://localhost:3000/reports/daily -o /dev/null
```

Watch the `app` CPU column in `docker stats` spike during report generation:

```
NAME        CPU %     MEM USAGE
app         94.3%     112MiB      ← report running, event loop blocked
```

### Step 3: Place a burst of orders and watch memory

Run 50 rapid requests:

```bash
for i in $(seq 1 50); do
  curl -s -b cookies.txt -X POST http://localhost:3000/orders \
    -H "Content-Type: application/json" \
    -d '{"productId": 1, "quantity": 1}' > /dev/null
done
```

Watch memory grow during the burst. Node.js holds open connections and session data in heap memory. It does not release it immediately.

### Step 4: Document your findings

Write down the answers to these questions — they will guide your AWS architecture decisions:

| Question | Your answer |
|---|---|
| Which container uses the most CPU during a report? | |
| Which container uses the most memory under load? | |
| What happens to API latency when the report runs? | |
| What happens to in-flight requests when the app container dies? | |
| Can two app containers share session data? | |

These five answers are the inputs to the architecture decisions in Phases 1–8. Every AWS service you introduce resolves one item on this list.

---

## What you have observed

| Failure mode | Root cause | Fixed in |
|---|---|---|
| In-flight requests lost on crash | No graceful shutdown, stateful in-process work | Phase 6 (SQS decoupling) |
| Sessions lost under horizontal scale | Sessions stored in process memory | Phase 2 (ElastiCache Redis) |
| API latency spikes during reports | CPU-bound work blocks the Node.js event loop | Phase 7 (Lambda) |
| No way to add a second server without breaking auth | No shared session store | Phase 2 (ElastiCache) |
| Manual deploys take down the entire app | Single deployable unit | Phase 3 (ECS rolling deploys) |

## Outcome

You now have a running local OrderFlow instance and a documented list of the top 5 problems to solve before this system can run reliably on AWS. Every subsequent phase resolves one of them.

---

[Back to main README](../README.md) | [Next: Phase 1 — AWS Foundations](../phase-1-foundations/README.md)
