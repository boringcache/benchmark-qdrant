#!/usr/bin/env python3
"""Verify Qdrant's integration-test image benchmark plan."""

import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = ["docker", "buildx", "build", "--file", "upstream/Dockerfile", "--build-arg", "PROFILE=ci", "--build-arg", "FEATURES=data-consistency-check,staging", "--load", "--tag", "qdrant/qdrant:e2e-tests", "upstream"]

def require(value: bool, message: str) -> None:
    if not value:
        raise RuntimeError(message)

def main() -> int:
    try:
        command = tomllib.loads((ROOT / ".boringcache.toml").read_text())["adapters"]["docker"]["command"]
        require(command == EXPECTED, "Docker plan changed")
        upstream = (ROOT / "upstream/.github/workflows/integration-tests.yml").read_text()
        for fragment in ("PROFILE=ci", "FEATURES=data-consistency-check,staging", "load: true", "tags: qdrant/qdrant:e2e-tests"):
            require(fragment in upstream, f"upstream integration build changed: {fragment}")
        action = (ROOT / ".github/actions/qdrant-docker-benchmark/action.yml").read_text()
        require(action.count("PROFILE=ci") == 1, "Actions/cache profile drifted")
        require(action.count("FEATURES=data-consistency-check,staging") == 1, "Actions/cache features drifted")
        require(action.count("push: false") == 1 and action.count("load: true") == 1, "Actions/cache output transport drifted")
        require(action.count("e2e-tests") == 2, "integration image tag drifted")
        require(action.count("uses: boringcache/one") == 2, "BoringCache phases drifted")
    except (KeyError, OSError, RuntimeError, tomllib.TOMLDecodeError) as error:
        print(f"Qdrant recipe mismatch: {error}", file=sys.stderr)
        return 1
    print("Verified Qdrant integration-test image plan.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
