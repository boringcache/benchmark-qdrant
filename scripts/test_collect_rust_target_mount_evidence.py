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
parse_observability_events = module.parse_observability_events
merge_events = module.merge_events
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
        self.assertTrue(payload["publish_complete"])

    def test_uses_terminal_publish_events_from_managed_trace(self) -> None:
        log = '''
#8 boringcache cache mount hydrate cacheID="/qdrant-cargo-target" status=miss archive="target-new" http_status=404
'''
        trace = '''
{"operation":"cache_session_summary","buildkit":{"mountcache":{"samples":[{"event":"mountcache_publish_archive_built","cache_id":"/qdrant-cargo-target","compressed_bytes":739526718,"uncompressed_bytes":3464012613,"file_count":8915},{"event":"mountcache_publish_done","cache_id":"/qdrant-cargo-target","compressed_bytes":739526718,"uncompressed_bytes":3464012613,"file_count":8915}]}}}
'''
        pattern = "^/?qdrant-cargo-target$"
        payload = summarize(
            merge_events(
                parse_events(log, pattern),
                parse_observability_events(trace, pattern),
            ),
            pattern,
        )

        self.assertEqual(payload["classification"], "seeded")
        self.assertEqual(payload["current_compressed_bytes"], 739_526_718)
        self.assertEqual(payload["current_files"], 8_915)
        self.assertTrue(payload["publish_complete"])

    def test_rejects_miss_without_terminal_publish_evidence(self) -> None:
        log = '''
#8 boringcache cache mount hydrate cacheID="/qdrant-cargo-target" status=miss archive="target-new" http_status=404
'''
        events = parse_events(log, "^/?qdrant-cargo-target$")

        with self.assertRaisesRegex(ValueError, "did not complete"):
            summarize(events, "^/?qdrant-cargo-target$")


if __name__ == "__main__":
    unittest.main()
