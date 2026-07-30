#!/usr/bin/env python3
from __future__ import annotations

import unittest
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path


spec = spec_from_file_location(
    "collect_rust_target_mount_evidence",
    Path(__file__).with_name("collect-rust-target-mount-evidence.py"),
)
assert spec is not None and spec.loader is not None
module = module_from_spec(spec)
spec.loader.exec_module(module)
parse_events = module.parse_events
summarize = module.summarize


class CollectRustTargetMountEvidenceTest(unittest.TestCase):
    def test_reports_rolling_target_archive_growth(self) -> None:
        log = """
#8 boringcache cache mount hydrate cacheID="/qdrant-cargo-target" status=hit archive="target-old" compressedBytes=10000000 transfer=stream total=1s
#19 boringcache cache mount publish cacheID="/qdrant-cargo-target" status=archive_built compressedBytes=10000061 uncompressedBytes=50000000 files=120 archive=1s
#19 boringcache cache mount publish cacheID="/qdrant-cargo-target" status=published compressedBytes=10000061 total=1s
"""
        payload = summarize(
            parse_events(log, "^/?qdrant-cargo-target$"),
            "^/?qdrant-cargo-target$",
        )

        self.assertEqual(payload["classification"], "stable")
        self.assertEqual(payload["compressed_bytes_delta"], 61)
        self.assertEqual(payload["current_uncompressed_bytes"], 50_000_000)
        self.assertEqual(payload["current_files"], 120)


if __name__ == "__main__":
    unittest.main()
