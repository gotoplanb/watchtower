# rust-build — sandboxed cargo over HTTP (local-only)

A generic toolchain runner for the Conduct code-generation eval flywheel
([gotoplanb/conduct#22](https://github.com/gotoplanb/conduct/issues/22) /
[#24](https://github.com/gotoplanb/conduct/issues/24),
[gotoplanb/watchtower#1](https://github.com/gotoplanb/watchtower/issues/1)).

**Local-only — like SonarQube.** It lives in `docker-compose.yml`, not in
`terragrunt/`, and is never cloud-deployed. Code generation is a *local research
capability* on owned hardware; the cloud deploy of Conduct only routes/evaluates
user-invoked tasks.

## What it is (and isn't)

It is intentionally **dumb**: accept a Cargo project tarball + a list of logical
commands, run each in a fresh temp workdir, return raw results. It knows nothing
about scoring — Conduct's `code_eval` evaluator interprets the output. Keeping it
generic is what lets the contract stay stable while Conduct's scoring evolves.

## Contract

```
POST /build
  {"project_tar_b64": "<base64 tar of a Cargo project>",
   "commands": ["check", "build", "test"],  # subset of: check build clippy test
   "overlay_files": {"tests/golden.rs": "..."},  # optional: written into the
                                                 # project before running (e.g. a
                                                 # harness-authored test suite)
   "test_target": "golden",            # optional: scopes `test` to
                                       # `cargo test --test golden`
   "timeout_s": 120}                   # optional, per-command
->
  {"results": {"check": {"exit": 0, "timed_out": false, "ms": 1234,
                         "stdout": "...", "stderr": "..."}, ...}}

GET /health -> 200 "ok"
```

`overlay_files` lets the caller inject golden/property test files (and, if a
suite needs a dev-dependency like `proptest`, a merged `Cargo.toml`) before the
run. `test_target` isolates one integration test so its pass-rate can be scored
on its own. Conduct parses the raw `cargo test` output into pass-rates and
proptest counterexamples — the service stays dumb.

Bad input → `400 {"error": "<reason>", "detail": "..."}` (e.g. `missing_tar`,
`bad_base64`, `no_cargo_toml`, `unknown_command`, `invalid_path`).

## Run / test

```bash
docker compose up -d rust-build          # part of the Watchtower stack
curl localhost:8055/health               # -> ok
python3 -m unittest test_build_runner    # orchestration tests (no cargo needed)
```

The host port is **8055** → container `8080`. The Conduct worker reaches it at
`http://host.docker.internal:8055` (set `RUST_BUILD_URL`).

## Threat model

A crate's `build.rs` and tests execute arbitrary code, so this **container is the
blast radius**: it runs non-root with a bounded per-command timeout and an
ephemeral workdir per request. Acceptable for local research on owned hardware
with our own models. Future hardening if untrusted code becomes a concern:
per-request container teardown, network egress lockdown, seccomp.
