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
TRACE_EVENT_MAP = {
    "mountcache_hydrate_hit": ("hydrate", "hit"),
    "mountcache_hydrate_miss": ("hydrate", "miss"),
    "mountcache_hydrate_miss_all": ("hydrate", "miss_all"),
    "mountcache_hydrate_skip": ("hydrate", "skip"),
    "mountcache_publish_archive_built": ("publish", "archive_built"),
    "mountcache_publish_done": ("publish", "published"),
    "mountcache_publish_skip": ("publish", "skip"),
    "mountcache_publish_error": ("publish", "error"),
}


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


def parse_observability_events(
    jsonl: str, cache_id_pattern: str
) -> list[dict[str, Any]]:
    wanted = re.compile(cache_id_pattern)
    events: list[dict[str, Any]] = []
    for line in jsonl.splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or record.get("operation") != "cache_session_summary":
            continue

        candidates = [record, record.get("summary"), record.get("details")]
        for candidate in candidates:
            if not isinstance(candidate, dict):
                continue
            buildkit = candidate.get("buildkit")
            if not isinstance(buildkit, dict):
                continue
            mountcache = buildkit.get("mountcache")
            if not isinstance(mountcache, dict):
                continue
            samples = mountcache.get("samples")
            if not isinstance(samples, list):
                continue
            for sample in samples:
                if not isinstance(sample, dict):
                    continue
                trace_event = sample.get("event")
                cache_id = sample.get("cache_id")
                if not isinstance(trace_event, str):
                    continue
                mapped = TRACE_EVENT_MAP.get(trace_event)
                if (
                    mapped is None
                    or not isinstance(cache_id, str)
                    or not wanted.search(cache_id)
                ):
                    continue
                phase, status = mapped
                event: dict[str, Any] = {
                    "phase": phase,
                    "cache_id": cache_id,
                    "status": status,
                    "source": "managed_buildkit_trace",
                }
                for source, target in (
                    ("compressed_bytes", "compressedBytes"),
                    ("uncompressed_bytes", "uncompressedBytes"),
                    ("file_count", "files"),
                ):
                    value = sample.get(source)
                    if isinstance(value, int) and not isinstance(value, bool):
                        event[target] = value
                if isinstance(sample.get("archive_tag"), str):
                    event["archive"] = sample["archive_tag"]
                if isinstance(sample.get("reason"), str):
                    event["reason"] = sample["reason"]
                events.append(event)
    return events


def merge_events(*event_groups: list[dict[str, Any]]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    seen: set[str] = set()
    for group in event_groups:
        for event in group:
            identity = json.dumps(event, sort_keys=True)
            if identity in seen:
                continue
            seen.add(identity)
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
    archive_built = next(
        (
            event
            for event in reversed(events)
            if event["phase"] == "publish" and event["status"] == "archive_built"
        ),
        None,
    )
    published = next(
        (
            event
            for event in reversed(events)
            if event["phase"] == "publish" and event["status"] == "published"
        ),
        None,
    )
    current = archive_built or published
    no_write = any(
        event["phase"] == "publish"
        and event["status"] == "skip"
        and event.get("reason") in {"no_writes", "unchanged_archive"}
        for event in events
    )

    previous_bytes = previous.get("compressedBytes") if previous else None
    current_bytes = current.get("compressedBytes") if current else None
    compressed_delta = None
    if published is None and not (previous is not None and no_write):
        raise ValueError("Cache mount did not complete a publish or stable no-write lifecycle")

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
        "publish_complete": published is not None,
        "events": events,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--observability-jsonl", required=True, type=Path)
    parser.add_argument("--cache-id-pattern", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    events = merge_events(
        parse_events(args.log.read_text(), args.cache_id_pattern),
        parse_observability_events(
            args.observability_jsonl.read_text(), args.cache_id_pattern
        ),
    )
    payload = summarize(events, args.cache_id_pattern)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
