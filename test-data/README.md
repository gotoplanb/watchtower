# Watchtower Test Data Generator

Generates synthetic OTLP telemetry (traces, metrics, logs) to validate the full pipeline.

## Setup

```bash
cd test-data
pip install -r requirements.txt
```

## Usage

```bash
# Default: 10 req/s to localhost:4317 with 5% error rate
python generate.py

# Custom settings
python generate.py --endpoint localhost:4317 --rate 10 --error-rate 0.05
```

## What it generates

Simulates three services: `api-gateway`, `order-service`, `payment-service`.

Each request produces:
- A distributed trace with spans across all three services
- Metrics: `http.server.request.count`, `http.server.request.duration`, `http.server.error.count`
- Structured log lines correlated via `trace_id`
