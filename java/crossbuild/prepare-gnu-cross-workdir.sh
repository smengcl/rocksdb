#!/usr/bin/env bash
# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <cross-cache-root>" >&2
  exit 1
fi

CACHE_ROOT="$1"
WORK_DIR="${CACHE_ROOT}/work"
WORK_IMAGE="${CACHE_ROOT}/rocksdb-gnu-cross-work.sparsebundle"
WORK_IMAGE_SIZE="${ROCKSDB_GNU_CROSS_WORK_SIZE:-40g}"

mkdir -p "${CACHE_ROOT}"

ensure_case_sensitive_workdir() {
  local probe_dir="$1"
  local lower="${probe_dir}/codex-case-test"
  local upper="${probe_dir}/CODEX-case-test"

  mkdir -p "${probe_dir}"
  rm -rf "${lower}" "${upper}"
  mkdir "${lower}"
  if mkdir "${upper}" 2>/dev/null; then
    rmdir "${upper}" "${lower}"
    return 0
  fi
  rmdir "${lower}"
  return 1
}

case "$(uname -s)" in
  Darwin)
    if ! ensure_case_sensitive_workdir "${WORK_DIR}"; then
      if [ ! -d "${WORK_IMAGE}" ]; then
        hdiutil create \
          -size "${WORK_IMAGE_SIZE}" \
          -type SPARSEBUNDLE \
          -fs "Case-sensitive APFS" \
          -volname rocksdb-gnu-cross-work \
          "${WORK_IMAGE}" >/dev/null
      fi

      mkdir -p "${WORK_DIR}"
      if ! mount | grep -Fq "on ${WORK_DIR} "; then
        hdiutil attach "${WORK_IMAGE}" -mountpoint "${WORK_DIR}" -nobrowse -quiet
      fi
    fi
    ;;
  *)
    mkdir -p "${WORK_DIR}"
    ;;
esac

echo "${WORK_DIR}"
