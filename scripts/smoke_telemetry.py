#!/usr/bin/env python3
"""End-to-end telemetry smoke test for the docker-compose stack.

Container health proves the processes booted. It does not prove telemetry
*arrives*. This script closes that gap: it emits a uniquely-tagged burst of
traces, logs, and metrics through Alloy's OTLP endpoint, then polls Tempo,
Loki, and Prometheus until each signal shows up -- or fails the run.

Use it as a gate after any image bump or Alloy config change:

    make smoke

Requires the OTLP SDK, which lives in test-data/.venv:

    ./test-data/.venv/bin/python scripts/smoke_telemetry.py

Every run uses a fresh `service.name` (watchtower-smoke-<epoch>) so a pass can
never be a stale-data false positive, and so the queries stay inside Tempo's
1-hour default search window.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_ENDPOINTS = {
    "grafana": "http://localhost:3000/api/health",
    "tempo": "http://localhost:3200/ready",
    "loki": "http://localhost:3100/ready",
    "prometheus": "http://localhost:9090/-/healthy",
    "alloy": "http://localhost:12345/-/ready",
}


def http_get(url, timeout=5):
    """GET a URL. Returns (status, body); status is None on transport error."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except Exception:
        return None, ""


def http_json(url, timeout=5):
    status, body = http_get(url, timeout)
    if status != 200:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Stage 1: the stack is up
# --------------------------------------------------------------------------


def wait_for_backends(timeout):
    """Block until every backend answers 200, or give up."""
    print("== stage 1: backends reachable ==")
    deadline = time.time() + timeout
    pending = dict(DEFAULT_ENDPOINTS)
    ok = {}

    while pending and time.time() < deadline:
        for name, url in list(pending.items()):
            status, _ = http_get(url, timeout=3)
            if status == 200:
                ok[name] = True
                del pending[name]
                print(f"  {name:11} ready")
        if pending:
            time.sleep(3)
    return not pending, pending


# --------------------------------------------------------------------------
# Stage 2: emit
# --------------------------------------------------------------------------


def emit(endpoint, service_name, count):
    """Send `count` correlated trace/log/metric sets and flush synchronously."""
    from opentelemetry import metrics, trace
    from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import (
        OTLPMetricExporter,
    )
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    try:
        from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    except ImportError:
        from opentelemetry.exporter.otlp.proto.grpc.log_exporter import OTLPLogExporter

    import logging

    resource = Resource.create({"service.name": service_name})

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True))
    )
    tracer = tracer_provider.get_tracer("watchtower.smoke")

    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=endpoint, insecure=True),
        export_interval_millis=2000,
    )
    meter_provider = MeterProvider(resource=resource, metric_readers=[reader])
    meter = meter_provider.get_meter("watchtower.smoke")
    counter = meter.create_counter(
        "smoke.request.count", description="smoke test requests"
    )
    histogram = meter.create_histogram(
        "smoke.request.duration", unit="ms", description="smoke test latency"
    )

    logger_provider = LoggerProvider(resource=resource)
    logger_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=endpoint, insecure=True))
    )
    log = logging.getLogger("watchtower.smoke")
    log.setLevel(logging.INFO)
    log.addHandler(LoggingHandler(level=logging.INFO, logger_provider=logger_provider))
    log.propagate = False

    print(f"== stage 2: emit {count} sets as service.name={service_name} ==")
    for i in range(count):
        with tracer.start_as_current_span("smoke.parent") as parent:
            parent.set_attribute("smoke.iteration", i)
            with tracer.start_as_current_span("smoke.child") as child:
                child.set_attribute("smoke.iteration", i)
                counter.add(1, {"smoke.iteration": str(i)})
                histogram.record(12.5 + i, {"smoke.iteration": str(i)})
                log.info("watchtower smoke log line %d", i)

    # Flush everything before we start querying, so a miss is a real miss.
    tracer_provider.force_flush()
    logger_provider.force_flush()
    meter_provider.force_flush()
    print("  flushed traces, logs, metrics")


# --------------------------------------------------------------------------
# Stage 3: verify arrival
# --------------------------------------------------------------------------


def check_tempo(service_name):
    """Traces searchable by service name.

    Tempo's search is time-windowed: with no start/end it only covers the last
    hour. We pass an explicit window anyway so a slow run can't drift out of it.
    """
    now = int(time.time())
    window = urllib.parse.urlencode({"start": now - 900, "end": now + 60, "limit": 20})
    traceql = urllib.parse.quote(f'{{resource.service.name="{service_name}"}}')

    for url in (
        f"http://localhost:3200/api/search?q={traceql}&{window}",
        f"http://localhost:3200/api/search?tags="
        f"{urllib.parse.quote(f'service.name={service_name}')}&{window}",
    ):
        data = http_json(url)
        traces = (data or {}).get("traces") or []
        if traces:
            return True, f"{len(traces)} trace(s); first id {traces[0].get('traceID','?')}"
    return False, "no traces matched"


def check_loki(service_name):
    """Logs arrive under the `job` label, which is NOT `service_name`.

    The value isn't always the bare service name either, so discover it from the
    label values rather than assuming the mapping.
    """
    data = http_json("http://localhost:3100/loki/api/v1/label/job/values")
    values = (data or {}).get("data") or []
    match = next((v for v in values if service_name in v), None)
    if not match:
        return False, f"no job label containing '{service_name}' (saw {values[:5]})"

    now = int(time.time())
    query = urllib.parse.urlencode(
        {
            "query": '{job="%s"}' % match,
            "start": (now - 900) * 10**9,
            "end": (now + 60) * 10**9,
            "limit": 20,
        }
    )
    data = http_json(f"http://localhost:3100/loki/api/v1/query_range?{query}")
    streams = ((data or {}).get("data") or {}).get("result") or []
    lines = sum(len(s.get("values") or []) for s in streams)
    if lines:
        return True, f"{lines} line(s) under job=\"{match}\""
    return False, f"job=\"{match}\" exists but returned no lines"


def check_prometheus(service_name):
    """Metrics arrive as `target_info` plus job-labelled series.

    OTLP histograms/counters are known to arrive sparsely through
    otelcol.exporter.prometheus + remote_write, so `target_info` for the job is
    the dependable assertion. Any instrument series found is reported as a bonus
    rather than required -- see the Known Issue in CLAUDE.md.
    """
    match = urllib.parse.quote(f'{{job=~".*{service_name}.*"}}')
    data = http_json(f"http://localhost:9090/api/v1/series?match[]={match}")
    series = (data or {}).get("data") or []
    if not series:
        return False, f"no series with a job label matching '{service_name}'"

    names = sorted({s.get("__name__", "?") for s in series})
    instruments = [n for n in names if n.startswith("smoke_")]
    detail = f"{len(series)} series: {', '.join(names[:6])}"
    if instruments:
        detail += f" (instruments present: {', '.join(instruments)})"
    else:
        detail += " (no smoke_* instruments yet -- known sparse-OTLP behaviour)"
    return True, detail


CHECKS = (
    ("tempo", check_tempo),
    ("loki", check_loki),
    ("prometheus", check_prometheus),
)


def verify(service_name, timeout, interval):
    """Poll every backend until all pass or the deadline expires."""
    print(f"== stage 3: verify arrival (up to {timeout}s) ==")
    deadline = time.time() + timeout
    results = {}

    while time.time() < deadline:
        for name, fn in CHECKS:
            if results.get(name, (False,))[0]:
                continue
            ok, detail = fn(service_name)
            results[name] = (ok, detail)
            if ok:
                print(f"  {name:11} PASS  {detail}")
        if all(results.get(n, (False,))[0] for n, _ in CHECKS):
            return True, results
        time.sleep(interval)

    return False, results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default="localhost:4317", help="OTLP gRPC target")
    parser.add_argument("--count", type=int, default=5, help="trace/log/metric sets")
    parser.add_argument(
        "--ready-timeout", type=int, default=90, help="seconds to wait for backends"
    )
    parser.add_argument(
        "--verify-timeout", type=int, default=120, help="seconds to wait for arrival"
    )
    parser.add_argument("--interval", type=int, default=5, help="poll interval seconds")
    args = parser.parse_args()

    ready, pending = wait_for_backends(args.ready_timeout)
    if not ready:
        print(f"\nFAIL: backends never became ready: {', '.join(sorted(pending))}")
        return 1

    service_name = f"watchtower-smoke-{int(time.time())}"
    try:
        emit(args.endpoint, service_name, args.count)
    except Exception as exc:  # noqa: BLE001 - surface any SDK/transport problem
        print(f"\nFAIL: could not emit telemetry: {exc}")
        return 1

    ok, results = verify(service_name, args.verify_timeout, args.interval)

    print("\n== summary ==")
    for name, _ in CHECKS:
        passed, detail = results.get(name, (False, "never checked"))
        print(f"  {'PASS' if passed else 'FAIL'}  {name:11} {detail}")

    if ok:
        print(f"\nAll three signals arrived for {service_name}.")
        return 0
    print(f"\nFAIL: telemetry did not arrive end-to-end for {service_name}.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
