#!/usr/bin/env python3
"""rust-build: a generic, local-only "sandboxed cargo over HTTP" runner.

Part of the Conduct code-generation eval flywheel (gotoplanb/conduct#22 / #24,
gotoplanb/watchtower#1). This service is intentionally DUMB: it accepts a Cargo
project tarball + a list of logical commands, runs each in a fresh temp workdir
inside this container, and returns raw results. It knows nothing about scoring —
Conduct's code_eval evaluator interprets the output.

Local-only: runs in Watchtower's compose alongside SonarQube, never in cloud
terragrunt. Generated code is compiled/run here (a crate's build.rs and tests
execute arbitrary code), so this container is the blast radius — non-root,
bounded per-command timeout, ephemeral workdir per request.

Stdlib only (no pip) so the Dockerfile is just the Rust toolchain + python3.

Contract
--------
  POST /build
    {"project_tar_b64": "<base64 tar>", "commands": ["check", "build"],
     "timeout_s": 120}
  -> 200 {"results": {"check": {"exit": 0, "timed_out": false, "ms": 1234,
                                "stdout": "...", "stderr": "..."}, ...}}
  -> 400 {"error": "<reason>", "detail": "..."}   (bad input)
  GET /health -> 200 "ok"
"""

from __future__ import annotations

import base64
import binascii
import io
import json
import os
import subprocess  # noqa: S404 - this service's whole job is running the toolchain
import tarfile
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path, PurePosixPath

# Logical command -> argv. The runner owns the toolchain invocation so callers
# never hardcode cargo flags. Extend here for clippy/test/mutants over time.
COMMANDS = {
    "check": ["cargo", "check", "--quiet", "--message-format=short"],
    "build": ["cargo", "build", "--quiet", "--message-format=short"],
    "clippy": ["cargo", "clippy", "--quiet", "--message-format=short", "--", "-D", "warnings"],
    "test": ["cargo", "test", "--quiet"],
    # Mutation testing (#28) — run the crate's OWN tests against mutants to find
    # shallow tests. Slow; callers pass a generous timeout_s.
    "mutants": ["cargo", "mutants", "--no-shuffle", "--colors", "never"],
}
DEFAULT_TIMEOUT_S = int(os.environ.get("RUST_BUILD_TIMEOUT_S", "120"))
MAX_TAR_BYTES = 4 * 1024 * 1024  # decoded tar cap
MAX_OUTPUT_CHARS = 20_000  # truncate captured stdout/stderr per command


class BuildError(ValueError):
    """A structured bad-request — returned as 400, never crashes the server."""

    def __init__(self, reason: str, detail: str = "") -> None:
        self.reason = reason
        self.detail = detail
        super().__init__(f"{reason}: {detail}" if detail else reason)


def _truncate(s: str) -> str:
    return s if len(s) <= MAX_OUTPUT_CHARS else s[:MAX_OUTPUT_CHARS] + "\n...[truncated]"


def _safe_extract(tar_bytes: bytes, dest: str) -> None:
    """Extract with the same zip-slip guard the artifact writer uses: reject
    absolute paths, ``..`` components, and non-file/dir members."""
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tar:
        for m in tar.getmembers():
            p = PurePosixPath(m.name)
            if p.is_absolute() or any(part == ".." for part in p.parts):
                raise BuildError("invalid_path", m.name)
            if not (m.isfile() or m.isdir()):
                raise BuildError("invalid_member", m.name)
        tar.extractall(dest)  # noqa: S202 - members validated just above


def _project_root(base: str) -> str:
    """The dir containing Cargo.toml (root, or a single top-level subdir)."""
    root = Path(base)
    if (root / "Cargo.toml").is_file():
        return str(root)
    for found in root.rglob("Cargo.toml"):
        return str(found.parent)
    raise BuildError("no_cargo_toml")


def run_one(workdir: str, argv: list[str], timeout_s: int) -> dict:
    """Run one command, capturing exit/stdout/stderr/timing. A timeout returns
    a structured ``timed_out`` result rather than raising."""
    start = time.monotonic()
    env = {**os.environ, "CARGO_TERM_COLOR": "never"}
    try:
        proc = subprocess.run(  # noqa: S603 - argv is from the trusted COMMANDS map
            argv, cwd=workdir, capture_output=True, text=True, timeout=timeout_s, env=env,
        )
    except subprocess.TimeoutExpired:
        return {
            "exit": None, "timed_out": True,
            "ms": int((time.monotonic() - start) * 1000),
            "stdout": "", "stderr": _truncate(f"timed out after {timeout_s}s"),
        }
    except FileNotFoundError as e:
        raise BuildError("toolchain_missing", argv[0]) from e
    return {
        "exit": proc.returncode, "timed_out": False,
        "ms": int((time.monotonic() - start) * 1000),
        "stdout": _truncate(proc.stdout), "stderr": _truncate(proc.stderr),
    }


def _write_overlay(workdir: str, overlay_files: dict) -> None:
    """Write caller-supplied files (e.g. a harness-authored test suite) into the
    extracted project before running commands. Same zip-slip guard as extract."""
    for path, content in overlay_files.items():
        p = PurePosixPath(str(path))
        if p.is_absolute() or any(part == ".." for part in p.parts):
            raise BuildError("invalid_overlay_path", str(path))
        if not isinstance(content, str):
            raise BuildError("invalid_overlay", f"{path} content is not a string")
        dest = Path(workdir) / p
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content)


def _argv_for(cmd: str, commands_map: dict, test_target: str | None) -> list[str]:
    """Resolve a logical command to argv. A `test` command scoped to a specific
    integration test target becomes `cargo test --test <target> ...` so a single
    suite's pass-rate can be measured in isolation."""
    base = commands_map[cmd]
    if cmd == "test" and test_target:
        return [base[0], base[1], "--test", test_target, *base[2:]]
    return base


def build_from_request(payload: dict, *, commands_map: dict | None = None, runner=run_one) -> dict:
    """Validate a /build payload, extract the tarball to a fresh temp dir,
    overlay any caller files, and run each requested command in sequence.
    ``commands_map``/``runner`` are injectable for tests (non-cargo commands)."""
    commands_map = commands_map or COMMANDS
    tar_b64 = payload.get("project_tar_b64")
    if not isinstance(tar_b64, str) or not tar_b64:
        raise BuildError("missing_tar")
    try:
        tar_bytes = base64.b64decode(tar_b64, validate=True)
    except (binascii.Error, ValueError) as e:
        raise BuildError("bad_base64", str(e)) from e
    if len(tar_bytes) > MAX_TAR_BYTES:
        raise BuildError("tar_too_large", f"{len(tar_bytes)} bytes (> {MAX_TAR_BYTES})")

    commands = payload.get("commands") or ["check"]
    unknown = [c for c in commands if c not in commands_map]
    if unknown:
        raise BuildError("unknown_command", ", ".join(unknown))
    timeout_s = int(payload.get("timeout_s") or DEFAULT_TIMEOUT_S)
    overlay_files = payload.get("overlay_files") or {}
    test_target = payload.get("test_target")

    results: dict[str, dict] = {}
    with tempfile.TemporaryDirectory(prefix="rb-") as tmp:
        _safe_extract(tar_bytes, tmp)
        workdir = _project_root(tmp)
        _write_overlay(workdir, overlay_files)
        for cmd in commands:
            results[cmd] = runner(workdir, _argv_for(cmd, commands_map, test_target), timeout_s)
    return {"results": results}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self._send(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/build":
            self._send(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except ValueError:
            self._send(400, {"error": "bad_json"})
            return
        try:
            self._send(200, build_from_request(payload))
        except BuildError as e:
            self._send(400, {"error": e.reason, "detail": e.detail})
        except Exception as e:  # noqa: BLE001 - one bad build must not kill the server
            self._send(500, {"error": "internal", "detail": str(e)[:300]})

    def log_message(self, *_args) -> None:  # silence per-request logging
        pass


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()  # noqa: S104


if __name__ == "__main__":
    main()
