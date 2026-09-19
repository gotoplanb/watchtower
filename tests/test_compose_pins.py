"""Guard the image pins in docker-compose.yml.

Why this exists: prometheus, grafana, alloy and sonarqube were all running on
floating tags (`:latest`, `:community`). That makes `make docker-up`
irreproducible -- two machines, or the same machine a month apart, silently get
different software, and a dependency-check routine can't see or report those
upgrades at all. These tests fail the moment a floating tag comes back.

Run:
    make test
    # or, with no Make:
    python3 -m unittest discover -s tests -v
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
COMPOSE_FILE = REPO_ROOT / "docker-compose.yml"

# Tags that move under you. `community`/`lts` are SonarQube's; the rest are the
# usual suspects. Compared case-insensitively against the tag only.
FLOATING_TAGS = frozenset(
    {
        "latest",
        "community",
        "lts",
        "lts-community",
        "stable",
        "edge",
        "main",
        "master",
        "nightly",
        "dev",
        "devel",
    }
)

# Services that regressed to a floating tag before (2026-09-19). Listed by name
# so that deleting the pin is a loud, named failure rather than a silent one.
PREVIOUSLY_FLOATING = ("prometheus", "grafana", "alloy", "sonarqube")

# Alloy 1.x is what docker/alloy-config.d/pipeline.alloy is written against --
# CLAUDE.md records the component names (otelcol.exporter.loki, .prometheus)
# as verified on the 1.x line. A 2.x jump needs a config review first, so fail
# here rather than at container start.
MAJOR_PINS = {"alloy": 1}


def split_image(ref):
    """Split an image reference into (name, tag, digest).

    Handles registry ports (`localhost:5000/img:tag`) and digest pins
    (`img@sha256:...`). Returns tag=None when no tag is present.
    """
    digest = None
    if "@" in ref:
        ref, digest = ref.split("@", 1)
    # A colon is only a tag separator if no "/" follows it.
    idx = ref.rfind(":")
    if idx != -1 and "/" not in ref[idx:]:
        return ref[:idx], ref[idx + 1 :], digest
    return ref, None, digest


def _strip_comment(line):
    """Drop a trailing ` #` comment. Image refs never contain '#'."""
    idx = line.find(" #")
    return line[:idx] if idx != -1 else line


def load_services():
    """Map service name -> {"image": ref, "build": ...} from docker-compose.yml.

    Deliberately dependency-free. This repo has no requirements file and no
    virtualenv for tests, so `make test` has to pass on a bare `python3` --
    importing PyYAML here would make the guard fail to run at all, which is
    worse than the drift it's guarding against.

    The parse is narrow on purpose: it only needs the immediate children of
    `services:` and their `image:` / `build:` values, which is a flat,
    two-level slice of the file.
    """
    services = {}
    in_services = False
    service_indent = None
    current = None

    for raw in COMPOSE_FILE.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        line = _strip_comment(raw).rstrip()
        if not line:
            continue

        indent = len(line) - len(line.lstrip())
        stripped = line.strip()

        if indent == 0:
            in_services = stripped.startswith("services:")
            current = None
            continue
        if not in_services:
            continue

        if service_indent is None:
            service_indent = indent

        if indent == service_indent and stripped.endswith(":"):
            current = stripped[:-1].strip()
            services[current] = {}
            continue

        if current is not None and indent > service_indent:
            for key in ("image", "build"):
                if stripped.startswith(key + ":"):
                    value = stripped[len(key) + 1 :].strip().strip("'\"")
                    # A nested `build:` block has no inline value; its mere
                    # presence is all the image-pin tests need.
                    services[current][key] = value or True

    return services


class ComposeFileTests(unittest.TestCase):
    """The compose file itself is well-formed."""

    def test_compose_file_exists(self):
        self.assertTrue(COMPOSE_FILE.is_file(), f"missing {COMPOSE_FILE}")

    def test_compose_file_parses(self):
        services = load_services()
        self.assertIsInstance(services, dict)
        for name, spec in services.items():
            with self.subTest(service=name):
                self.assertIsInstance(spec, dict, f"service '{name}' did not parse")

    def test_has_services(self):
        self.assertTrue(load_services(), "docker-compose.yml declares no services")


class ImagePinTests(unittest.TestCase):
    """Every service image names a specific version."""

    @classmethod
    def setUpClass(cls):
        cls.services = load_services()

    def test_every_service_declares_an_image(self):
        # A service may legitimately `build:` instead of pulling an image.
        for name, spec in self.services.items():
            with self.subTest(service=name):
                self.assertTrue(
                    spec.get("image") or spec.get("build"),
                    f"service '{name}' has neither 'image' nor 'build'",
                )

    def test_no_floating_tags(self):
        for name, spec in self.services.items():
            image = spec.get("image")
            if not image:
                continue
            repo, tag, digest = split_image(image)
            with self.subTest(service=name, image=image):
                if digest and not tag:
                    continue  # digest-pinned is the strongest form
                self.assertIsNotNone(
                    tag,
                    f"service '{name}' image '{image}' has no tag "
                    f"(implicitly ':latest')",
                )
                self.assertNotIn(
                    tag.lower(),
                    FLOATING_TAGS,
                    f"service '{name}' uses floating tag '{tag}' "
                    f"-- pin it to a specific version",
                )

    def test_tag_contains_a_version_number(self):
        """`16-alpine` and `v1.19.2` pass; `slim` or `community` do not."""
        for name, spec in self.services.items():
            image = spec.get("image")
            if not image:
                continue
            _, tag, digest = split_image(image)
            if tag is None and digest:
                continue
            with self.subTest(service=name, image=image):
                self.assertRegex(
                    tag or "",
                    r"\d",
                    f"service '{name}' tag '{tag}' carries no version number",
                )

    def test_previously_floating_services_stay_pinned(self):
        for name in PREVIOUSLY_FLOATING:
            with self.subTest(service=name):
                self.assertIn(name, self.services, f"service '{name}' disappeared")
                image = self.services[name].get("image", "")
                _, tag, digest = split_image(image)
                self.assertTrue(
                    digest or (tag and tag.lower() not in FLOATING_TAGS),
                    f"service '{name}' regressed to a floating tag: '{image}'",
                )

    def test_pinned_majors_match_the_configs_we_wrote(self):
        for name, expected_major in MAJOR_PINS.items():
            with self.subTest(service=name):
                self.assertIn(name, self.services)
                image = self.services[name].get("image", "")
                _, tag, digest = split_image(image)
                if tag is None and digest:
                    # Digest-pinned: stronger than a tag, and the major isn't
                    # readable from the reference. Nothing to check here.
                    self.skipTest(f"service '{name}' is digest-pinned")
                match = re.match(r"v?(\d+)", tag or "")
                self.assertIsNotNone(
                    match, f"can't read a major version out of '{tag}'"
                )
                self.assertEqual(
                    int(match.group(1)),
                    expected_major,
                    f"service '{name}' moved off the {expected_major}.x line "
                    f"('{tag}') -- review docker/alloy-config.d/ before pinning this",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
