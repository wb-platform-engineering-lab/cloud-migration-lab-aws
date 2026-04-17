# Phase 13 — Data Platform & AI

> **AWS services introduced:** Kinesis, Glue, Athena, QuickSight, Amazon Forecast, Amazon Bedrock | **Daily cost:** ~$36/day (incremental ~$2.20 over Phase 12)

## Objective

OrderFlow processes 400,000 orders per day — but that data is locked in RDS and only accessible to engineers with SQL access. This phase unlocks it: build a streaming data lake for analytics, train an ML model to predict inventory demand, and add a GenAI order assistant powered by Amazon Bedrock.

## AWS services

| Service | Why we need it |
|---|---|
| **Kinesis Data Streams** | Real-time event ingestion from the Orders API |
| **Kinesis Firehose** | Buffers, compresses, and lands events in S3 |
| **AWS Glue** | Serverless ETL — transforms raw JSON to partitioned Parquet |
| **Athena** | Serverless SQL on S3 — no warehouse to provision |
| **QuickSight** | Self-service BI dashboards for non-technical stakeholders |
| **Amazon Forecast** | Time-series ML — predicts demand per product SKU |
| **Amazon Bedrock** | Managed foundation models (Claude) — no GPU, no training |
| **Bedrock Knowledge Bases** | RAG — grounds LLM answers in real order and product data |

## Directory structure

```
phase-13-data-ai/
├── terraform/
│   ├── kinesis.tf          # Data Stream + Firehose delivery stream
│   ├── s3_lake.tf          # Data lake bucket + lifecycle policies
│   ├── glue.tf             # Glue database, crawler, ETL job
│   ├── athena.tf           # Athena workgroup + query results bucket
│   ├── quicksight.tf       # QuickSight data source + dataset
│   ├── forecast.tf         # Forecast dataset group + IAM roles
│   ├── bedrock_kb.tf       # Knowledge Base + OpenSearch Serverless collection
│   └── variables.tf
├── glue-jobs/
│   └── orders_etl.py       # PySpark: raw JSON → partitioned Parquet
├── forecast/
│   ├── export_dataset.py   # Export 90 days of order history to Forecast CSV format
│   └── import_predictions.py # Read Forecast output → update RDS reorder_threshold
└── assistant/
    └── handler.js          # Lambda: POST /assistant/ask → Bedrock RetrieveAndGenerate
```

## Architecture

```
Orders API → Kinesis Data Streams → Kinesis Firehose → S3 (raw JSON)
                                                              ↓
                                                    Glue ETL (nightly)
                                                              ↓
                                                    S3 (curated Parquet, partitioned by date)
                                                         ↓             ↓
                                                      Athena       Amazon Forecast
                                                         ↓             ↓
                                                    QuickSight    Lambda → RDS reorder_threshold

S3 (order status exports, refreshed every 15 min by Lambda)
    ↓
Bedrock Knowledge Base (chunked + embedded → OpenSearch Serverless)
    ↓
POST /assistant/ask → Bedrock RetrieveAndGenerate → natural language answer
```

## Track A — Data Platform

### S3 data lake layout

```
s3://orderflow-data-lake/
├── raw/orders/YYYY/MM/DD/          ← Firehose lands here (GZIP JSON)
└── curated/orders_daily/
    └── year=2026/month=04/day=17/  ← Glue writes Parquet here (partitioned)
```

Partitioning is critical — Athena charges per byte scanned. A query scoped to a date partition reads only that partition, not the entire history.

### Glue ETL job

The nightly PySpark job in `glue-jobs/orders_etl.py`:
1. Reads raw GZIP JSON from the previous day's S3 prefix
2. Casts types, adds `year`/`month`/`day` partition columns
3. Writes Parquet to the curated prefix
4. Updates the Glue Data Catalog partition metadata

### QuickSight dashboard

Three visuals for the CFO:
- Revenue by day (line chart with 30-day rolling average)
- Top 20 products by units sold (bar chart)
- Order volume by region (filled map)

## Track B — AI

### Demand forecasting (Amazon Forecast)

Provide 90 days of `(product_id, date, units_sold)` history. Forecast trains a predictor with an 8-week horizon and generates P10/P50/P90 confidence bounds per SKU. A Lambda reads the export and writes updated `reorder_threshold` values to RDS.

Train once, export predictions, delete the predictor (pay only for training + inference, not idle time).

### Order assistant (Amazon Bedrock + RAG)

```
POST /assistant/ask
  {"question": "Where is order #8821?"}

→ Knowledge Base retrieves relevant order status chunks
→ Bedrock (Claude) answers in natural language:
  "Your order #8821 shipped on April 15th via DHL, tracking number XYZ..."
```

The Knowledge Base is backed by S3 documents: order status exports (refreshed every 15 minutes), product FAQ, and shipping policy. Bedrock chunks, embeds, and indexes these into OpenSearch Serverless. No fine-tuning required.

**RAG vs fine-tuning:** Order data changes by the second — fine-tuning produces a snapshot that is stale within hours. RAG stays current because it reads from S3 at query time.

## Challenges

1. **Kinesis pipeline**: Publish `OrderCreated` and `OrderShipped` events from the Orders API to Kinesis. Configure Firehose to buffer 60 seconds, GZIP compress, and land in S3. Verify events arrive within 2 minutes.
2. **Glue ETL**: Write a PySpark Glue job that reads raw JSON, converts to Parquet, partitions by date. Schedule with Glue Triggers at midnight UTC.
3. **Athena + QuickSight**: Create the Glue Data Catalog table. Run a query for 30-day daily revenue. Connect QuickSight and build the CFO dashboard.
4. **Amazon Forecast**: Export 90 days of product order history. Create a Dataset Group, import, train a predictor (56-day horizon). Export predictions and write a Lambda that updates `reorder_threshold` in RDS.
5. **Bedrock Knowledge Base**: Create a Knowledge Base backed by S3. Write a Lambda that exports recent order statuses every 15 minutes. Confirm retrieval by querying a specific order ID.
6. **Order assistant API**: Add `POST /assistant/ask` to the Orders API. Call Bedrock `RetrieveAndGenerate`. Add Cognito authorizer — authenticated users only.
7. **Cost guardrail**: Track daily Bedrock token usage in DynamoDB. Add a Lambda authorizer that rejects requests once the daily budget (500,000 tokens) is exceeded.

## Cost breakdown

| Resource | $/day |
|---|---|
| Kinesis Data Streams (2 shards) | $0.72 |
| Kinesis Firehose (~5 MB/day) | $0.02 |
| S3 data lake | $0.01 |
| Glue ETL (2 DPU × 15 min/night) | $0.07 |
| Athena (~100 MB scanned/day) | $0.01 |
| QuickSight (1 author) | $0.60 |
| Bedrock Claude Haiku (~50K tokens/day) | $0.04 |
| Bedrock Knowledge Base (0.5 OCU) | $0.72 |
| Amazon Forecast (training — one-time) | ~$2–5 total |
| **Incremental over Phase 12** | **~$2.20/day** |

> Delete the Forecast predictor after exporting predictions — you keep the CSVs in S3 and only retrain deliberately.

```bash
cd terraform && terraform destroy -auto-approve
```

---

[Back to main README](../README.md)
