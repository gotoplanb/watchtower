# Using gcx with Watchtower

[`gcx`](https://github.com/grafana/gcx) is Grafana's CLI for managing Grafana resources, designed for agentic coding tools. It works fine against this local stack and gives Claude Code (or any coding agent) structured access to dashboards, logs, traces, and metrics without leaving the terminal.

This doc covers what's specific to using it here — install, local auth, and the gotchas worth knowing.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/grafana/gcx/main/scripts/install.sh | sh
```

Installs to `~/.local/bin/gcx`. Verify with `gcx version`.

## Authenticating against local Grafana

Local Grafana (admin/watchtower) accepts service-account tokens. A service account named **`gcx-explorer`** (Admin role) already exists for this purpose — if its token is lost, mint a new one from the Grafana UI (Administration → Service accounts) or via the API:

```sh
SA_ID=$(curl -s -u admin:watchtower 'http://localhost:3000/api/serviceaccounts/search' \
  | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin)['serviceAccounts'] if s['name']=='gcx-explorer']")

TOKEN=$(curl -s -u admin:watchtower -X POST "http://localhost:3000/api/serviceaccounts/${SA_ID}/tokens" \
  -H 'Content-Type: application/json' -d '{"name":"gcx-cli-'"$(date +%s)"'"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

gcx login local --server http://localhost:3000 --token "$TOKEN"
```

The login stores the token in `~/.config/gcx/config.yaml` under context `local`. From then on, `gcx <cmd>` uses it automatically.

## Useful queries

```sh
gcx datasources list                                          # confirm Loki/Prometheus/Tempo wired
gcx dashboards list --json metadata.name,spec.title           # what's provisioned
gcx logs query '{job="watchtower-generator"}' --since 5m      # trace-correlated log bodies
gcx traces query '{}' --since 15m --limit 5                   # recent traces (rootService, durationMs, …)
gcx traces labels                                             # full TraceQL tag inventory
gcx metrics query 'sum by (handler)(rate(grafana_http_request_duration_seconds_count[5m]))' --since 1h
gcx traces query '{}' --share-link                            # prints a Grafana Explore URL to stderr
```

## Gotchas

- **Agent mode auto-enables.** gcx detects `CLAUDECODE` / `CLAUDE_CODE` (and other agent env vars) and switches to structured JSON output with no color. Great when an AI tool is invoking it; a bit verbose when you're reading it yourself. Use `--no-color` only, or pipe through `jq` if you want pretty.
- **`--json field1,field2` doesn't traverse arrays.** `--json traces.rootServiceName` returns `null` because the response shape is `traces: [...]`. For array contents, omit `--json` (agent mode already emits JSON), or use the literal field names that appear at the top level.
- **Flag drift across subcommands.** `gcx traces query` takes `--since`; `gcx traces labels` does **not**. Always check `gcx <subcommand> --help` rather than assuming flags are shared.
- **TraceQL metrics needs pipe syntax.** Write `{} | rate() by (resource.service.name)`, not `rate() by (resource.service.name)`. Even with valid syntax, short windows over local Tempo sometimes return `series: []` — widen the `--since` window.
- **`target_info{job="watchtower-generator"}` may be empty.** This is the known OTLP→Prometheus dropoff described in CLAUDE.md (Known Issue: Sparse OTLP Metrics), not a gcx problem. Traces and logs are unaffected and query reliably.
- **Tempo search is time-windowed.** gcx hands `--since` through to Tempo, but Tempo itself defaults to a 1-hour search window and caps explicit windows at 168h. See the Tempo notes in CLAUDE.md for the full diagnostic story.
- **Token visibility.** `gcx --log-http-payload` logs full request bodies, **including the `Authorization: Bearer …` header**. Don't paste that output anywhere. Same goes for `~/.config/gcx/config.yaml` — it stores the token in cleartext.

## Related capabilities not yet exercised here

- `gcx dev` — manage Grafana resources as code; would pair well with the empty `dashboards/` dir.
- `gcx agent` / `gcx commands` / `gcx help-tree` — capability discovery surfaces explicitly built for AI agents.
- `gcx assistant` — interact with Grafana Assistant (Grafana Cloud feature; unlikely to do anything useful against local OSS).
