#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


EVENT_PATTERN = re.compile(
    r'boringcache cache mount (?P<phase>hydrate|publish) '
    r'cacheID="(?P<cache_id>[^"]+)" status=(?P<status>[a-z_]+)(?P<details>.*)$'
)
NUMBER_PATTERN = re.compile(
    r"(?P<key>compressedBytes|uncompressedBytes|files)=(?P<value>\d+)"
)
ARCHIVE_PATTERN = re.compile(r'archive="(?P<archive>[^"]+)"')
REASON_PATTERN = re.compile(r"reason=(?P<reason>[a-z_]+)")


def parse_events(log: str, cache_id_pattern: str) -> list[dict[str, Any]]:
    wanted = re.compile(cache_id_pattern)
    events: list[dict[str, Any]] = []
    for line in log.splitlines():
        match = EVENT_PATTERN.search(line)
        if not match or not wanted.search(match.group("cache_id")):
            continue

        event: dict[str, Any] = {
            "phase": match.group("phase"),
            "cache_id": match.group("cache_id"),
            "status": match.group("status"),
        }
        details = match.group("details")
        for number in NUMBER_PATTERN.finditer(details):
            event[number.group("key")] = int(number.group("value"))
        if archive := ARCHIVE_PATTERN.search(details):
            event["archive"] = archive.group("archive")
        if reason := REASON_PATTERN.search(details):
            event["reason"] = reason.group("reason")
        events.append(event)
    return events


def summarize(events: list[dict[str, Any]], cache_id_pattern: str) -> dict[str, Any]:
    cache_ids = sorted({event["cache_id"] for event in events})
    if not cache_ids:
        raise ValueError(
            f"No BuildKit cache-mount events matched {cache_id_pattern!r}"
        )

    previous = next(
        (
            event
            for event in reversed(events)
            if event["phase"] == "hydrate" and event["status"] == "hit"
        ),
        None,
    )
    current = next(
        (
            event
            for event in reversed(events)
            if event["phase"] == "publish" and event["status"] == "archive_built"
        ),
        None,
    )
    no_write = any(
        event["phase"] == "publish"
        and event["status"] == "skip"
        and event.get("reason") in {"no_writes", "unchanged_archive"}
        for event in events
    )

    previous_bytes = previous.get("compressedBytes") if previous else None
    current_bytes = current.get("compressedBytes") if current else None
    compressed_delta = None
    classification = "seeded"
    if previous_bytes is not None and current_bytes is not None:
        compressed_delta = current_bytes - previous_bytes
        stable_limit = max(1024 * 1024, round(previous_bytes * 0.001))
        if abs(compressed_delta) <= stable_limit:
            classification = "stable"
        elif compressed_delta > 0:
            classification = "growing"
        else:
            classification = "shrinking"
    elif previous_bytes is not None and no_write:
        compressed_delta = 0
        classification = "stable"

    return {
        "schema_version": "rust_target_mount_growth.v1",
        "cache_id_pattern": cache_id_pattern,
        "cache_ids": cache_ids,
        "classification": classification,
        "previous_compressed_bytes": previous_bytes,
        "current_compressed_bytes": current_bytes,
        "compressed_bytes_delta": compressed_delta,
        "current_uncompressed_bytes": (
            current.get("uncompressedBytes") if current else None
        ),
        "current_files": current.get("files") if current else None,
        "events": events,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--cache-id-pattern", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    payload = summarize(
        parse_events(args.log.read_text(), args.cache_id_pattern),
        args.cache_id_pattern,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
