# benchmark-qdrant

Isolated Qdrant Docker cache benchmark for BoringCache versus GitHub Actions cache.

Qdrant is a strong evidence-first prospect because its public integration
workflow builds the same Rust-in-Docker image twice and exports two
`type=gha,mode=max` caches on successful `dev` pushes. The repository also has
active work specifically aimed at making those Docker builds reuse cache more
reliably.

## Prospect Evidence

Public `dev` run
[`30079491988`](https://github.com/qdrant/qdrant/actions/runs/30079491988)
used the pinned source revision in this repository:

- e2e image: 266.4 seconds exporting the GHA cache
- consensus image: 168.4 seconds exporting the GHA cache
- combined cache export work in that run: 434.8 seconds

Across five sampled successful `dev` pushes, combined export time ranged from
6.5 to 434.8 seconds, with a 290.1-second median. Qdrant ran 285 `dev` push
workflows in the 30 days ending 2026-07-24, or about 9.5 per day. At the time
of inspection its Actions cache API reported about 14.87 GB across 1,469
entries.

The pain is current and explicit:

- merged PR [`#8786`](https://github.com/qdrant/qdrant/pull/8786) stopped PR
  cache writes to reduce LRU eviction pressure
- open PR [`#8820`](https://github.com/qdrant/qdrant/pull/8820) continues work
  on Docker build caches for long e2e and consistency tests
- open PR [`#8822`](https://github.com/qdrant/qdrant/pull/8822) experiments
  with a persistent local Buildx cache

Qdrant already uses `Swatinem/rust-cache` for native Rust jobs. The claim here
is narrower: its Docker integration jobs still pay remote BuildKit cache
transfer costs and do not use a third-party Docker cache accelerator.

## Source Model

- Upstream source lives in the pinned `upstream/` submodule.
- Workflows build the upstream root `Dockerfile` unchanged with `upstream/` as
  the Docker context.
- Build arguments mirror the 266.4-second e2e job:
  `PROFILE=ci` and `FEATURES=data-consistency-check,staging`.
- The initial proof uses `linux/amd64`.

Pinned upstream source:

- `94fdd0e74684b9d5299b8deaec6ed3fa908c35ea`

The Dockerfile already makes dependency compilation ordinary cargo-chef image
layers. That makes external BuildKit cache the correct first experiment; this
benchmark does not modify the Dockerfile or add sccache inside the image.

## Scenarios

- `cold`
- `warm1`

The fresh lane runs a no-prior-cache cold build plus exactly one warm rerun on
the same pinned source tree. The rolling lane records the upstream commit
build as-is after each upstream sync and skips `warm1`.

BoringCache uses its external registry/OCI BuildKit cache path. It does not
run BoringCache inside upstream Dockerfile `RUN` steps. The optional
BoringCache BuildKit-backend and ECR lanes remain disabled until their
repository variables are configured.

## Output

Each workflow uploads machine-readable JSON and Markdown summaries for later
ingestion by the central `boringcache/benchmarks` publisher.

## Token Model

- `BORINGCACHE_RESTORE_TOKEN` for read-only restore and proxy access
- `BORINGCACHE_SAVE_TOKEN` for trusted write paths
- `BORINGCACHE_API_TOKEN` only where a single bearer variable is still
  required for compatibility
