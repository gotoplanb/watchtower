#!/usr/bin/env python3
"""
Synthetic telemetry generator for Watchtower.

Simulates a multi-service application that produces distributed traces,
metrics, and structured logs via OTLP gRPC. Sends telemetry to Alloy
(or any OTLP-compatible endpoint).

Services simulated:
  - api-gateway:     receives HTTP requests, forwards to backend
  - order-service:   processes orders, writes to database
  - payment-service: handles payment processing

Each simulated request produces:
  - A distributed trace with spans across all three services
  - Metrics: request count, latency histogram, error rate
  - Structured log lines correlated via trace_id
"""

import argparse
import logging
import random
import sys
import time

from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor

try:
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
except ImportError:
    from opentelemetry.exporter.otlp.proto.grpc.log_exporter import OTLPLogExporter

from opentelemetry.trace import StatusCode


# HTTP paths and methods for simulation
ENDPOINTS = [
    ("GET", "/api/orders"),
    ("POST", "/api/orders"),
    ("GET", "/api/orders/{id}"),
    ("POST", "/api/payments"),
    ("GET", "/api/health"),
]

ERROR_MESSAGES = [
    "Connection timeout to database",
    "Payment gateway returned 503",
    "Order validation failed: missing required field",
    "Rate limit exceeded",
    "Internal server error",
]


def create_providers(endpoint: str):
    """Set up OpenTelemetry trace, metrics, and log providers."""
    resource = Resource.create({"service.name": "watchtower-generator"})

    # Traces
    trace_exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    trace_provider = TracerProvider(resource=resource)
    trace_provider.add_span_processor(BatchSpanProcessor(trace_exporter))
    trace.set_tracer_provider(trace_provider)

    # Metrics
    metric_exporter = OTLPMetricExporter(endpoint=endpoint, insecure=True)
    metric_reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=5000)
    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

    # Logs
    log_exporter = OTLPLogExporter(endpoint=endpoint, insecure=True)
    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(log_exporter))

    handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.INFO)

    return trace_provider, meter_provider, logger_provider


def create_meters():
    """Create metric instruments."""
    meter = metrics.get_meter("watchtower-generator")

    request_counter = meter.create_counter(
        name="http.server.request.count",
        description="Total HTTP requests",
        unit="1",
    )
    request_duration = meter.create_histogram(
        name="http.server.request.duration",
        description="HTTP request duration",
        unit="ms",
    )
    error_counter = meter.create_counter(
        name="http.server.error.count",
        description="Total HTTP errors",
        unit="1",
    )

    return request_counter, request_duration, error_counter


def simulate_request(
    request_counter,
    request_duration,
    error_counter,
    error_rate: float,
):
    """Simulate a single multi-service request."""
    method, path = random.choice(ENDPOINTS)
    is_error = random.random() < error_rate
    order_id = random.randint(1000, 9999)

    # Replace path template
    actual_path = path.replace("{id}", str(order_id))

    gateway_tracer = trace.get_tracer("api-gateway")
    order_tracer = trace.get_tracer("order-service")
    payment_tracer = trace.get_tracer("payment-service")

    # --- api-gateway span ---
    with gateway_tracer.start_as_current_span(
        f"{method} {actual_path}",
        attributes={
            "http.method": method,
            "http.url": actual_path,
            "http.scheme": "https",
            "service.name": "api-gateway",
        },
    ) as gateway_span:
        gateway_latency = random.uniform(1, 10)
        time.sleep(gateway_latency / 1000)

        ctx = trace.get_current_span().get_span_context()
        trace_id = format(ctx.trace_id, "032x")

        logging.info(
            "Request received",
            extra={
                "trace_id": trace_id,
                "service": "api-gateway",
                "method": method,
                "path": actual_path,
            },
        )

        # --- order-service span ---
        with order_tracer.start_as_current_span(
            "process_order",
            attributes={
                "order.id": str(order_id),
                "service.name": "order-service",
            },
        ) as order_span:
            order_latency = random.uniform(5, 50)
            time.sleep(order_latency / 1000)

            logging.info(
                "Processing order",
                extra={
                    "trace_id": trace_id,
                    "service": "order-service",
                    "order_id": order_id,
                },
            )

            # --- payment-service span (only for POST /payments or POST /orders) ---
            payment_latency = 0
            if method == "POST":
                with payment_tracer.start_as_current_span(
                    "process_payment",
                    attributes={
                        "payment.order_id": str(order_id),
                        "payment.amount": f"{random.uniform(10, 500):.2f}",
                        "service.name": "payment-service",
                    },
                ) as payment_span:
                    payment_latency = random.uniform(10, 100)
                    time.sleep(payment_latency / 1000)

                    if is_error:
                        error_msg = random.choice(ERROR_MESSAGES)
                        payment_span.set_status(StatusCode.ERROR, error_msg)
                        payment_span.set_attribute("error", True)
                        logging.error(
                            error_msg,
                            extra={
                                "trace_id": trace_id,
                                "service": "payment-service",
                                "order_id": order_id,
                            },
                        )
                    else:
                        logging.info(
                            "Payment processed successfully",
                            extra={
                                "trace_id": trace_id,
                                "service": "payment-service",
                                "order_id": order_id,
                            },
                        )

        total_latency = gateway_latency + order_latency + payment_latency

        if is_error:
            status_code = random.choice([500, 502, 503])
            gateway_span.set_status(StatusCode.ERROR)
            gateway_span.set_attribute("http.status_code", status_code)
        else:
            status_code = 200
            gateway_span.set_attribute("http.status_code", status_code)

        # Record metrics
        labels = {
            "http.method": method,
            "http.route": path,
            "http.status_code": str(status_code),
        }
        request_counter.add(1, labels)
        request_duration.record(total_latency, labels)
        if is_error:
            error_counter.add(1, labels)

        logging.info(
            "Request completed",
            extra={
                "trace_id": trace_id,
                "service": "api-gateway",
                "status_code": status_code,
                "duration_ms": round(total_latency, 2),
            },
        )


def main():
    parser = argparse.ArgumentParser(description="Watchtower synthetic telemetry generator")
    parser.add_argument(
        "--endpoint",
        default="localhost:4317",
        help="OTLP gRPC endpoint (default: localhost:4317)",
    )
    parser.add_argument(
        "--rate",
        type=float,
        default=10,
        help="Requests per second (default: 10)",
    )
    parser.add_argument(
        "--error-rate",
        type=float,
        default=0.05,
        help="Error rate as fraction (default: 0.05 = 5%%)",
    )
    args = parser.parse_args()

    print(f"Watchtower Test Data Generator")
    print(f"  Endpoint:   {args.endpoint}")
    print(f"  Rate:       {args.rate} req/s")
    print(f"  Error rate: {args.error_rate * 100:.0f}%")
    print()

    trace_provider, meter_provider, logger_provider = create_providers(args.endpoint)
    request_counter, request_duration, error_counter = create_meters()

    interval = 1.0 / args.rate
    count = 0

    try:
        while True:
            simulate_request(request_counter, request_duration, error_counter, args.error_rate)
            count += 1
            if count % 100 == 0:
                print(f"  Sent {count} requests...")
            time.sleep(interval)
    except KeyboardInterrupt:
        print(f"\nStopping after {count} requests.")
    finally:
        trace_provider.shutdown()
        meter_provider.shutdown()
        logger_provider.shutdown()


if __name__ == "__main__":
    main()
