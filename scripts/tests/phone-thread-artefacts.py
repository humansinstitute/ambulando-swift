#!/usr/bin/env python3
"""Run real phone workspace state branches on macOS; not an iOS UI/device test.

First swift test --package-path AmbulandoCore --scratch-path <owned-core-build>.
Pass that scratch root and an owned output directory; clean those outputs after review.
"""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("core_build", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
core = args.core_build.resolve() / "arm64-apple-macosx/debug"
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
objects = [str(p) for name in ("AmbulandoCore", "CryptoSwift", "P256K", "libsecp256k1")
           for p in (core / (name + ".build")).rglob("*.o")]
if not objects or not (core / "Modules/AmbulandoCore.swiftmodule").exists():
    parser.error("Build AmbulandoCore for the arm64 Mac host first")
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-D", "AMBULANDO_PHONE_STATE_CHECK",
           "-I", str(core / "Modules"), "-Xcc", "-fmodule-map-file=" + str(core / "libsecp256k1.build/module.modulemap"),
           str(repo / "Ambulando/Views/ThreadArtefactState.swift"), str(repo / "scripts/tests/phone-thread-artefacts.swift"),
           *objects, "-lsqlite3", "-o", str(out / "phone-state-check")]
subprocess.run(command, cwd=repo, check=True)
subprocess.run([str(out / "phone-state-check")], cwd=repo, check=True)
