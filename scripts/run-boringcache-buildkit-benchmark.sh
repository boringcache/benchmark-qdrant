#!/usr/bin/env bash
set -euo pipefail

proxy_port="${BORINGCACHE_PROXY_PORT:-5000}"
proxy_log="${BORINGCACHE_PROXY_LOG_PATH:-/tmp/boringcache-proxy-${proxy_port}.log}"
build_log="$(mktemp /tmp/boringcache-build.XXXXXX.log)"
status_snapshot_path="$(mktemp /tmp/boringcache-status.XXXXXX.json)"
cache_export_pattern='expected sha256:.*got sha256:e3b0|error writing layer blob|400 Bad Request|broken pipe'
mode="${1:-full}"
cache_args=()
build_output="${BENCHMARK_BUILD_OUTPUT:-none}"
export BORINGCACHE_OBSERVABILITY_INCLUDE_CACHE_OPS="${BORINGCACHE_OBSERVABILITY_INCLUDE_CACHE_OPS:-1}"

find_step_id() {
  local pattern="$1"
  sed -nE "s/^#([0-9]+) ${pattern}.*/\\1/p" "$build_log" | tail -n1
}

find_step_seconds() {
  local step_id="$1"
  [[ -n "$step_id" ]] || return 0
  sed -nE "s/^#${step_id} DONE ([0-9]+(\\.[0-9]+)?)s$/\\1/p" "$build_log" | tail -n1
}

write_build_metrics() {
  local output_path="${BENCHMARK_METRICS_OUTPUT:-}"
  [[ -n "$output_path" ]] || return 0

  local import_step=""
  local export_step=""
  local import_seconds=""
  local export_seconds=""
  local import_status=""
  local cached_steps=""

  import_step="$(find_step_id "importing cache manifest from")"
  export_step="$(find_step_id "exporting cache to boringcache")"
  import_seconds="$(find_step_seconds "$import_step")"
  export_seconds="$(find_step_seconds "$export_step")"
  import_status="$(build_import_status)"
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$build_log" || true)"

  mkdir -p "$(dirname "$output_path")"
  : > "$output_path"
  echo "cache_import_status=$import_status" >> "$output_path"
  echo "buildkit_cached_steps=$cached_steps" >> "$output_path"
  if [[ -n "$import_seconds" ]]; then
    echo "docker_cache_import_seconds=$import_seconds" >> "$output_path"
  fi
  if [[ -n "$export_seconds" ]]; then
    echo "docker_cache_export_seconds=$export_seconds" >> "$output_path"
  fi
  if [[ -n "${BORINGCACHE_BLOB_DOWNLOAD_CONCURRENCY:-}" ]]; then
    echo "blob_download_concurrency_override=${BORINGCACHE_BLOB_DOWNLOAD_CONCURRENCY}" >> "$output_path"
  fi
  if [[ -n "${BORINGCACHE_BLOB_PREFETCH_CONCURRENCY:-}" ]]; then
    echo "blob_prefetch_concurrency_override=${BORINGCACHE_BLOB_PREFETCH_CONCURRENCY}" >> "$output_path"
  fi
  if [[ -n "${BORINGCACHE_OCI_STREAM_THROUGH_MIN_BYTES:-}" ]]; then
    echo "oci_stream_through_min_bytes=${BORINGCACHE_OCI_STREAM_THROUGH_MIN_BYTES}" >> "$output_path"
  fi
  if [[ -s "$status_snapshot_path" ]] && command -v jq >/dev/null 2>&1; then
    append_status_metric() {
      local key="$1"
      local jq_expr="$2"
      local value=""
      value="$(jq -r "$jq_expr // empty" "$status_snapshot_path" 2>/dev/null || true)"
      if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$key=$value" >> "$output_path"
      fi
    }

    append_status_metric oci_hydration_policy '.startup_prefetch.startup_prefetch_oci_hydration'
    append_status_metric startup_oci_body_inserted '.startup_prefetch.startup_prefetch_oci_body_inserted'
    append_status_metric startup_oci_body_failures '.startup_prefetch.startup_prefetch_oci_body_failures'
    append_status_metric startup_oci_body_cold_blobs '.startup_prefetch.startup_prefetch_oci_body_cold_blobs'
    append_status_metric startup_oci_body_duration_ms '.startup_prefetch.startup_prefetch_oci_body_duration_ms'
    append_status_metric oci_body_local_hits '.oci_body.oci_body_local_hits'
    append_status_metric oci_body_remote_fetches '.oci_body.oci_body_remote_fetches'
    append_status_metric oci_body_local_bytes '.oci_body.oci_body_local_bytes'
    append_status_metric oci_body_remote_bytes '.oci_body.oci_body_remote_bytes'
    append_status_metric oci_body_local_duration_ms '.oci_body.oci_body_local_duration_ms'
    append_status_metric oci_body_remote_duration_ms '.oci_body.oci_body_remote_duration_ms'
    append_status_metric proxy_blob_download_max_concurrency '.session_summary.proxy.blob_download_max_concurrency'
    append_status_metric proxy_blob_prefetch_max_concurrency '.session_summary.proxy.blob_prefetch_max_concurrency'
    append_status_metric proxy_blob_prefetch_concurrency_source '.session_summary.proxy.blob_prefetch_concurrency_source'
    append_status_metric oci_stream_through_count '.oci_engine.oci_engine_stream_through_count'
    append_status_metric oci_stream_through_bytes '.oci_engine.oci_engine_stream_through_bytes'
    append_status_metric oci_stream_through_verify_duration_ms '.oci_engine.oci_engine_stream_through_verify_duration_ms'
    append_status_metric oci_stream_through_verify_failures '.oci_engine.oci_engine_stream_through_verify_failures'
    append_status_metric oci_stream_through_cache_promotion_failures '.oci_engine.oci_engine_stream_through_cache_promotion_failures'
  fi

  local observability_path="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}"
  if [[ -n "$observability_path" && -s "$observability_path" ]] && command -v jq >/dev/null 2>&1; then
    detail_value() {
      local details="$1"
      local name="$2"
      printf '%s\n' "$details" | tr ' ' '\n' | awk -F= -v key="$name" '$1 == key { print $2; exit }'
    }
    append_metric() {
      local key="$1"
      local value="$2"
      if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$key=$value" >> "$output_path"
      fi
    }

    local plan_details=""
    plan_details="$(jq -r 'select(.operation == "oci_blob_upload_plan") | .details // empty' "$observability_path" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$plan_details" ]]; then
      append_metric oci_upload_requested_blobs "$(detail_value "$plan_details" requested_blobs)"
      append_metric oci_new_blob_count "$(detail_value "$plan_details" upload_urls)"
      append_metric oci_upload_already_present "$(detail_value "$plan_details" already_present)"
    else
      append_metric oci_new_blob_count "0"
    fi

    local uploaded_blob_bytes=""
    uploaded_blob_bytes="$(jq -s -r '
      ([range(0; length) as $i | select(.[$i].operation == "oci_blob_upload_plan") | $i] | last) as $plan
      | if $plan == null then
          0
        else
          ([range(($plan + 1); length) as $i | .[$i] | select(.operation == "oci_blob_upload") | (.request_bytes // 0)] | add // 0)
        end
    ' "$observability_path" 2>/dev/null || true)"
    append_metric oci_new_blob_bytes "${uploaded_blob_bytes:-0}"

    local batch_duration_ms=""
    batch_duration_ms="$(jq -r 'select(.operation == "oci_blob_upload_batch") | .duration_ms // empty' "$observability_path" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$batch_duration_ms" ]]; then
      awk -v ms="$batch_duration_ms" 'BEGIN { printf "oci_upload_batch_seconds=%.3f\n", ms / 1000 }' >> "$output_path"
    fi
  fi
}

capture_proxy_status() {
  local output_path="${1:-$status_snapshot_path}"
  curl -fsS "http://127.0.0.1:${proxy_port}/_boringcache/status" -o "$output_path" 2>/dev/null || true
}

build_import_status() {
  if grep -Eq 'failed to configure .*cache importer|cache manifest.*(manifest unknown|not found)|importing cache manifest.*(manifest unknown|not found)' "$build_log"; then
    echo "not_found"
  elif grep -Eq 'inferred cache manifest type|importing cache manifest' "$build_log"; then
    echo "ok"
  else
    echo "none"
  fi
}

write_build_diagnostics() {
  local output_path="${BENCHMARK_DIAGNOSTICS_OUTPUT:-}"
  [[ -n "$output_path" ]] || return 0

  local cached_steps=""
  cached_steps="$(grep -Ec '^#[0-9]+ CACHED$' "$build_log" || true)"
  local observability_path="${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}"

  mkdir -p "$(dirname "$output_path")"
  {
    echo "strategy=boringcache"
    echo "cache_backend=boringcache"
    echo "mode=${mode}"
    echo "cache_scope=${CACHE_SCOPE:-}"
    echo "blob_download_concurrency_override=${BORINGCACHE_BLOB_DOWNLOAD_CONCURRENCY:-}"
    echo "blob_prefetch_concurrency_override=${BORINGCACHE_BLOB_PREFETCH_CONCURRENCY:-}"
    echo "oci_stream_through_min_bytes=${BORINGCACHE_OCI_STREAM_THROUGH_MIN_BYTES:-}"
    printf 'cache_args='
    if [[ "${cache_args[*]-}" != "" ]]; then
      printf '%q ' "${cache_args[@]}"
    fi
    printf '\n'
    echo "import_status=$(build_import_status)"
    echo "cached_steps=${cached_steps}"
    echo "import_lines<<EOF"
    grep -E 'importing cache manifest|failed to configure .*cache importer|inferred cache manifest type' "$build_log" || true
    echo "EOF"
    echo "export_lines<<EOF"
    grep -E 'exporting cache to boringcache|DONE [0-9.]+s$' "$build_log" | tail -n 80 || true
    echo "EOF"
    echo "proxy_summary<<EOF"
    if [[ -s "$proxy_log" ]]; then
      grep -E 'Mode:|OCI Human Tags|Internal Registry Root Tag|Startup mode|Full-tag hydration|OCI body hydration|OCI HEAD|SESSION tool=oci|KV flush|root publish|error|warn' "$proxy_log" | tail -n 160 || true
    fi
    echo "EOF"
    echo "proxy_status<<EOF"
    if [[ -s "$status_snapshot_path" ]]; then
      cat "$status_snapshot_path"
    fi
    echo "EOF"
    echo "slow_done_lines<<EOF"
    grep -E '^#[0-9]+ DONE [0-9]+(\.[0-9]+)?s$' "$build_log" | tail -n 80 || true
    echo "EOF"
    echo "observability_jsonl=${observability_path}"
    if [[ -n "$observability_path" && -s "$observability_path" ]]; then
      printf 'observability_events='
      wc -l < "$observability_path" | tr -d ' '
      printf '\n'
      echo "observability_summary<<EOF"
      grep -E 'cache_session_summary|oci_blob_upload|upload_session_commit|cache_finalize_publish|receipt|429|rate' "$observability_path" | tail -n 160 || true
      echo "EOF"
    fi
  } > "$output_path"
}

run_wrapped_boringcache_build() {
  local phase_hint="cold"
  if [[ "$mode" == "partial-warm" ]]; then
    phase_hint="warm"
  elif [[ "${CACHE_LANE:-fresh}" == "rolling" ]]; then
    phase_hint="commit"
  fi

  local boringcache_args=(
    boringcache docker
    --workspace "${BENCHMARK_WORKSPACE:?Set BENCHMARK_WORKSPACE}"
    --tag "${CACHE_SCOPE:?Set CACHE_SCOPE}"
    --port "$proxy_port"
    --cache-mode max
    --no-platform
    --no-git
    --metadata-hint "benchmark=${BENCHMARK_ID:-docker}"
    --metadata-hint "phase=${phase_hint}"
    --metadata-hint "lane=${CACHE_LANE:-fresh}"
    --metadata-hint "backend=boringcache"
    --fail-on-cache-error
  )

  if [[ "$mode" == "partial-warm" ]]; then
    boringcache_args+=(--read-only)
  fi

  local wrapped_cache_args=()
  local cache_arg
  if [[ "${cache_args[*]-}" != "" ]]; then
    for cache_arg in "${cache_args[@]}"; do
      if [[ "$cache_arg" == "--no-cache" ]]; then
        wrapped_cache_args+=("$cache_arg")
      fi
    done
  fi

  : > "$build_log"
  set +e +u
  DOCKER_BUILDKIT=1 BORINGCACHE_TIMING_TRACE=1 boringcache "${boringcache_args[@]:1}" -- \
    docker buildx build \
    --file "$DOCKERFILE_PATH" \
    --tag "$IMAGE_TAG" \
    --progress=plain \
    "${extra_args[@]}" \
    "${wrapped_cache_args[@]}" \
    "${output_args[@]}" \
    "$BENCHMARK_DOCKER_CONTEXT" 2>&1 | tee "$build_log"
  status=${PIPESTATUS[0]}
  set -e -u
}

while true; do
  cache_args=()
  extra_args=()
  output_args=()
  while IFS= read -r arg; do
    [[ -n "$arg" ]] || continue
    extra_args+=("$arg")
  done <<< "${DOCKER_BUILD_EXTRA_ARGS:-}"

  case "$build_output" in
    none)
      ;;
    load)
      output_args+=(--load)
      ;;
    local-registry)
      output_args+=(--push)
      ;;
    *)
      echo "Unknown BENCHMARK_BUILD_OUTPUT: ${build_output}" >&2
      exit 1
      ;;
  esac

  if [[ "$mode" == "full" ]]; then
    :
  elif [[ "$mode" == "seed-cache" ]]; then
    # The seed must execute every Dockerfile step so the managed cache starts
    # from a complete, independently measurable baseline.
    cache_args=(--no-cache)
  elif [[ "$mode" == "partial-warm" ]]; then
    # The wrapper's read-only mode imports without exporting.
    :
  else
    echo "Unknown build mode: $mode" >&2
    exit 1
  fi

  run_wrapped_boringcache_build

  if [[ "$status" -eq 0 ]]; then
  import_status="$(build_import_status)"
  if [[ "$mode" == "partial-warm" && "$import_status" != "ok" ]]; then
    capture_proxy_status
    write_build_metrics
    echo "Warm build completed without a usable managed cache import (status: ${import_status}); refusing invalid fresh sample." >&2
    if [[ -n "${BENCHMARK_METRICS_OUTPUT:-}" && -s "$BENCHMARK_METRICS_OUTPUT" ]]; then
      cat "$BENCHMARK_METRICS_OUTPUT" >&2
    fi
    exit 1
  fi
  if [[ "$mode" =~ ^(full|seed-cache)$ ]] && grep -Eq "$cache_export_pattern" "$build_log"; then
    capture_proxy_status
    write_build_metrics
    write_build_diagnostics
    echo "Build succeeded but managed cache export reported an error; failing benchmark." >&2
    tail -n 200 "$build_log" || true
    tail -n 400 "$proxy_log" || true
    exit 1
  fi
  capture_proxy_status
  write_build_metrics
  write_build_diagnostics
  ./scripts/assert-boringcache-docker-product-run.sh "${BORINGCACHE_OBSERVABILITY_JSONL_PATH:-}"
  break
  fi

  echo "Build (${mode}) failed" >&2
  tail -n 200 "$build_log" || true
  write_build_diagnostics
  exit "$status"
done
