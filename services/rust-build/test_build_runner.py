"""Stdlib unittest for the rust-build runner (no pytest, no cargo needed).

The cargo-specific argv lives in COMMANDS and is exercised live via
`docker compose up rust-build`; here we test the orchestration (extract, run,
timeout, validation) by injecting non-cargo commands via `commands_map`/`runner`.

Run: python3 -m unittest services.rust_build.test_build_runner  (or in-dir:
     python3 -m unittest test_build_runner)
"""

from __future__ import annotations

import base64
import io
import sys
import tarfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import app  # noqa: E402


def _tar_b64(files: dict[str, str]) -> str:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name, content in files.items():
            data = content.encode()
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return base64.b64encode(buf.getvalue()).decode()


def _malicious_tar_b64(name: str) -> str:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        data = b"x"
        info = tarfile.TarInfo(name=name)
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    return base64.b64encode(buf.getvalue()).decode()


_CARGO = '[package]\nname = "sol"\nversion = "0.1.0"\nedition = "2021"\n'
# Fake "toolchain": python invocations standing in for cargo, so tests need no
# Rust installed.
_FAKE = {
    "check": [sys.executable, "-c", "import sys; print('checked'); sys.exit(0)"],
    "build": [sys.executable, "-c", "import sys; sys.stderr.write('error[E1]: boom\\n'); sys.exit(101)"],
}


class RunOneTests(unittest.TestCase):
    def test_success_captures_streams(self):
        r = app.run_one(".", [sys.executable, "-c", "import sys;print('out');sys.stderr.write('err')"], 10)
        self.assertEqual(r["exit"], 0)
        self.assertFalse(r["timed_out"])
        self.assertIn("out", r["stdout"])
        self.assertIn("err", r["stderr"])
        self.assertGreaterEqual(r["ms"], 0)

    def test_nonzero_exit(self):
        r = app.run_one(".", [sys.executable, "-c", "import sys;sys.exit(3)"], 10)
        self.assertEqual(r["exit"], 3)

    def test_timeout_is_structured(self):
        r = app.run_one(".", [sys.executable, "-c", "import time;time.sleep(5)"], 1)
        self.assertTrue(r["timed_out"])
        self.assertIsNone(r["exit"])
        self.assertIn("timed out", r["stderr"])

    def test_missing_toolchain_raises_structured(self):
        with self.assertRaises(app.BuildError) as cm:
            app.run_one(".", ["definitely-not-a-real-binary-xyz"], 5)
        self.assertEqual(cm.exception.reason, "toolchain_missing")


class BuildFromRequestTests(unittest.TestCase):
    def test_runs_each_command(self):
        payload = {"project_tar_b64": _tar_b64({"Cargo.toml": _CARGO, "src/main.rs": "fn main(){}"}),
                   "commands": ["check", "build"]}
        out = app.build_from_request(payload, commands_map=_FAKE)
        self.assertEqual(out["results"]["check"]["exit"], 0)
        self.assertEqual(out["results"]["build"]["exit"], 101)
        self.assertIn("error[E1]", out["results"]["build"]["stderr"])

    def test_default_command_is_check(self):
        payload = {"project_tar_b64": _tar_b64({"Cargo.toml": _CARGO})}
        out = app.build_from_request(payload, commands_map=_FAKE)
        self.assertEqual(list(out["results"]), ["check"])

    def test_bad_base64(self):
        with self.assertRaises(app.BuildError) as cm:
            app.build_from_request({"project_tar_b64": "!!!notbase64!!!"}, commands_map=_FAKE)
        self.assertEqual(cm.exception.reason, "bad_base64")

    def test_missing_tar(self):
        with self.assertRaises(app.BuildError) as cm:
            app.build_from_request({}, commands_map=_FAKE)
        self.assertEqual(cm.exception.reason, "missing_tar")

    def test_unknown_command(self):
        payload = {"project_tar_b64": _tar_b64({"Cargo.toml": _CARGO}), "commands": ["mutants"]}
        with self.assertRaises(app.BuildError) as cm:
            app.build_from_request(payload, commands_map=_FAKE)
        self.assertEqual(cm.exception.reason, "unknown_command")

    def test_no_cargo_toml(self):
        payload = {"project_tar_b64": _tar_b64({"src/main.rs": "fn main(){}"})}
        with self.assertRaises(app.BuildError) as cm:
            app.build_from_request(payload, commands_map=_FAKE)
        self.assertEqual(cm.exception.reason, "no_cargo_toml")

    def test_path_traversal_member_rejected(self):
        with self.assertRaises(app.BuildError) as cm:
            app.build_from_request({"project_tar_b64": _malicious_tar_b64("../escape.rs")}, commands_map=_FAKE)
        self.assertEqual(cm.exception.reason, "invalid_path")

    def test_finds_cargo_in_subdir(self):
        payload = {"project_tar_b64": _tar_b64({"adder/Cargo.toml": _CARGO, "adder/src/main.rs": "fn main(){}"})}
        out = app.build_from_request(payload, commands_map=_FAKE)
        self.assertEqual(out["results"]["check"]["exit"], 0)

    def test_overlay_files_are_written_into_project(self):
        # A fake "check" that exits 0 iff the overlaid suite file is present.
        check_overlay = {"check": [
            sys.executable, "-c",
            "import os,sys; sys.exit(0 if os.path.exists('tests/golden.rs') else 7)",
        ]}
        payload = {
            "project_tar_b64": _tar_b64({"Cargo.toml": _CARGO, "src/lib.rs": "pub fn f(){}"}),
            "overlay_files": {"tests/golden.rs": "#[test] fn g(){ assert!(true); }"},
        }
        out = app.build_from_request(payload, commands_map=check_overlay)
        self.assertEqual(out["results"]["check"]["exit"], 0)

    def test_overlay_path_traversal_rejected(self):
        payload = {
            "project_tar_b64": _tar_b64({"Cargo.toml": _CARGO}),
            "overlay_files": {"../escape.rs": "x"},
        }
        with self.assertRaises(app.BuildError) as cm:
            app.build_from_request(payload, commands_map=_FAKE)
        self.assertEqual(cm.exception.reason, "invalid_overlay_path")


class ArgvForTests(unittest.TestCase):
    def test_test_target_scopes_integration_test(self):
        self.assertEqual(
            app._argv_for("test", app.COMMANDS, "golden"),
            ["cargo", "test", "--test", "golden", "--quiet"],
        )

    def test_test_without_target_runs_all(self):
        self.assertEqual(app._argv_for("test", app.COMMANDS, None), ["cargo", "test", "--quiet"])

    def test_non_test_command_ignores_target(self):
        self.assertEqual(app._argv_for("check", app.COMMANDS, "golden"), app.COMMANDS["check"])


if __name__ == "__main__":
    unittest.main()
