#!/usr/bin/env python3
"""Scan every image in docker-compose.yml for known CVEs with Trivy.

Dependabot covers lockfiles in each repo; it does not look inside container
images. This fills that gap for the Watchtower stack (and, via --extra, the
locally built app images such as conduct:local).

Default view is HIGH/CRITICAL with a fix available: the list you can act on
by bumping a pin. --all-severities / --include-unfixed widen it.

Exit code: 0 clean, 1 if any CRITICAL with a fix was found, 2 on scan error.
"""
import argparse
import json
import shutil
import subprocess
import sys


def compose_images():
    out = subprocess.run(
        ["docker", "compose", "config", "--images"],
        check=True, capture_output=True, text=True,
    ).stdout
    return sorted(set(line.strip() for line in out.splitlines() if line.strip()))


def scan(image, severities, include_unfixed):
    cmd = ["trivy", "image", "--quiet", "--scanners", "vuln",
           "--severity", severities, "--format", "json", image]
    if not include_unfixed:
        cmd.insert(-1, "--ignore-unfixed")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip().splitlines()[-1] if proc.stderr else "trivy failed")
    vulns = []
    for result in json.loads(proc.stdout).get("Results", []):
        for v in result.get("Vulnerabilities") or []:
            vulns.append({
                "id": v["VulnerabilityID"],
                "severity": v["Severity"],
                "pkg": v["PkgName"],
                "installed": v["InstalledVersion"],
                "fixed": v.get("FixedVersion") or "-",
                "target": result.get("Target", ""),
            })
    # One CVE can hit the same package in several binaries; collapse those.
    seen, unique = set(), []
    for v in vulns:
        key = (v["id"], v["pkg"], v["installed"])
        if key not in seen:
            seen.add(key)
            unique.append(v)
    return unique


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--extra", nargs="*", default=[],
                    help="additional images to scan, e.g. conduct:local crossover:local")
    ap.add_argument("--all-severities", action="store_true",
                    help="include LOW and MEDIUM (default: HIGH,CRITICAL)")
    ap.add_argument("--include-unfixed", action="store_true",
                    help="include CVEs with no fixed version yet")
    args = ap.parse_args()

    if not shutil.which("trivy"):
        sys.exit("trivy not found -- brew install trivy")

    severities = "LOW,MEDIUM,HIGH,CRITICAL" if args.all_severities else "HIGH,CRITICAL"
    images = compose_images() + args.extra
    order = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3, "UNKNOWN": 4}

    critical_found, errors = False, False
    summary = []
    for image in images:
        print(f"== {image}", flush=True)
        try:
            vulns = scan(image, severities, args.include_unfixed)
        except Exception as e:  # noqa: BLE001 -- report and keep scanning the rest
            print(f"  ERROR  {e}")
            summary.append((image, None))
            errors = True
            continue
        vulns.sort(key=lambda v: (order.get(v["severity"], 9), v["pkg"]))
        for v in vulns:
            print(f"  {v['severity']:<8} {v['id']:<20} {v['pkg']} {v['installed']} -> {v['fixed']}  ({v['target']})")
        if not vulns:
            print("  clean")
        counts = {s: sum(1 for v in vulns if v["severity"] == s) for s in order}
        if counts["CRITICAL"] and any(v["fixed"] != "-" for v in vulns if v["severity"] == "CRITICAL"):
            critical_found = True
        summary.append((image, counts))

    print("\n== summary (" + severities + ("" if args.include_unfixed else ", fix available") + ") ==")
    for image, counts in summary:
        if counts is None:
            print(f"  {'ERROR':<10} {image}")
        else:
            print(f"  C={counts['CRITICAL']:<3} H={counts['HIGH']:<3}"
                  + (f" M={counts['MEDIUM']:<3} L={counts['LOW']:<3}" if args.all_severities else "")
                  + f" {image}")

    if errors:
        sys.exit(2)
    sys.exit(1 if critical_found else 0)


if __name__ == "__main__":
    main()
