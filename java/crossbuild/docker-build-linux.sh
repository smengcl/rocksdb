#!/usr/bin/env bash
# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.

set -e
#set -x

# Default to using all available cores when job parallelism is not defined.
if [ -z "${J}" ]; then
  J=100%
fi

# Support percentage-style values (e.g. J=100%) used by the top-level Makefile.
if [[ "${J}" == *% ]]; then
  J_PERCENT="${J%\%}"
  if [ -n "${J_PERCENT}" ] && [ "${J_PERCENT}" -gt 0 ] 2>/dev/null; then
    if hash nproc 2>/dev/null; then
      CPU_COUNT=$(nproc)
    else
      CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    fi
    J=$(( (CPU_COUNT * J_PERCENT + 99) / 100 ))
    if [ "${J}" -lt 1 ]; then
      J=1
    fi
  else
    J=1
  fi
fi

# Build defaults for release jars
export PORTABLE=1
export DISABLE_JEMALLOC="${DISABLE_JEMALLOC:-1}"

# Release artifact builds must never pick up sanitizer instrumentation.
unset COMPILE_WITH_ASAN COMPILE_WITH_TSAN COMPILE_WITH_UBSAN
unset ASAN_OPTIONS TSAN_OPTIONS UBSAN_OPTIONS

# just in-case this is run outside Docker
mkdir -p /rocksdb-local-build

rm -rf /rocksdb-local-build/*
cp -r /rocksdb-host/* /rocksdb-local-build
cd /rocksdb-local-build

# Optional GNU cross-compilation mode for building Linux JNI artifacts from an arm64 host.
if [ -n "${ROCKSDB_CROSS_TRIPLE:-}" ]; then
  echo "Configuring GNU cross-compile toolchain for ${ROCKSDB_CROSS_TRIPLE}"
  # shellcheck source=/dev/null
  source java/crossbuild/setup-gnu-cross.sh
  rocksdb_setup_gnu_cross_toolchain

  if [ "${ROCKSDB_PREPARE_GNU_CROSS_TOOLCHAIN_ONLY:-0}" = "1" ]; then
    echo "Prepared GNU cross toolchain cache for ${ROCKSDB_CROSS_TRIPLE}"
    exit 0
  fi
fi

# Keep the historical GCC workaround for regular builds.
if [ -z "${EXTRA_CXXFLAGS:-}" ]; then
  EXTRA_CXXFLAGS=""
fi
if [ -z "${EXTRA_CFLAGS:-}" ]; then
  EXTRA_CFLAGS=""
fi
if [ -z "${EXTRA_LDFLAGS:-}" ]; then
  EXTRA_LDFLAGS=""
fi

EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -fno-sanitize=undefined -fno-sanitize=address -fno-sanitize=thread"
EXTRA_CFLAGS="${EXTRA_CFLAGS} -fno-sanitize=undefined -fno-sanitize=address -fno-sanitize=thread"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS} -fno-sanitize=undefined -fno-sanitize=address -fno-sanitize=thread"

if [ -z "${ROCKSDB_CROSS_TRIPLE:-}" ]; then
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -Wno-error=restrict"
fi

export EXTRA_CXXFLAGS
export EXTRA_CFLAGS
export EXTRA_LDFLAGS

rewrite_musl_libc_needed() {
  local native_path="$1"
  local native_name
  local expected_loader=""
  local dynamic_dump=""

  native_name="$(basename "${native_path}")"
  case "${native_name}" in
    librocksdbjni-linux32-musl.so)
      expected_loader='libc.musl-x86.so.1'
      ;;
    librocksdbjni-linux64-musl.so)
      expected_loader='libc.musl-x86_64.so.1'
      ;;
    librocksdbjni-linux-aarch64-musl.so)
      expected_loader='libc.musl-aarch64.so.1'
      ;;
    librocksdbjni-linux-ppc64le-musl.so)
      expected_loader='libc.musl-ppc64le.so.1'
      ;;
    librocksdbjni-linux-s390x-musl.so)
      expected_loader='libc.musl-s390x.so.1'
      ;;
    *)
      return 0
      ;;
  esac

  if hash objdump 2>/dev/null; then
    dynamic_dump="$(objdump -p "${native_path}" 2>/dev/null || true)"
  elif hash readelf 2>/dev/null; then
    dynamic_dump="$(readelf -d "${native_path}" 2>/dev/null || true)"
  else
    return 0
  fi

  if printf '%s\n' "${dynamic_dump}" | grep -Eq "${expected_loader}"; then
    return 0
  fi

  if ! printf '%s\n' "${dynamic_dump}" | grep -Eq 'NEEDED[[:space:]]+libc\.so$'; then
    return 0
  fi

  if ! hash patchelf 2>/dev/null; then
    echo "patchelf is required to rewrite musl libc dependency in ${native_path}"
    exit 1
  fi

  patchelf --replace-needed libc.so "${expected_loader}" "${native_path}"
}

validate_no_sanitizer_refs() {
  local native_path="$1"
  local symbol_dump=""
  local pattern='__ubsan_|__asan_|__tsan_'

  if hash nm 2>/dev/null; then
    symbol_dump=$(nm -D "${native_path}" 2>/dev/null || true)
  elif hash readelf 2>/dev/null; then
    symbol_dump=$(readelf -Ws "${native_path}" 2>/dev/null || true)
  else
    echo "Neither nm nor readelf is available to validate sanitizer refs in ${native_path}"
    exit 1
  fi

  if printf '%s\n' "${symbol_dump}" | grep -Eq "${pattern}"; then
    echo "Unexpected sanitizer runtime reference in ${native_path}"
    printf '%s\n' "${symbol_dump}" | grep -E "${pattern}" || true
    exit 1
  fi
}

validate_gnu_cxx_abi() {
  local native_path="$1"
  local symbol_dump=""
  local dynamic_dump=""
  local string_dump=""
  local has_gnu_abi=0
  local libcxx_symbol_pattern='NSt3__1|St3__1'
  local gnucxx_symbol_pattern='St7__cxx11'

  if hash nm 2>/dev/null; then
    symbol_dump="$(nm -D "${native_path}" 2>/dev/null || true)"
  elif hash readelf 2>/dev/null; then
    symbol_dump="$(readelf -Ws "${native_path}" 2>/dev/null || true)"
  fi

  if printf '%s\n' "${symbol_dump}" | grep -Eq "${libcxx_symbol_pattern}"; then
    echo "Unexpected libc++ symbol namespace in ${native_path}"
    printf '%s\n' "${symbol_dump}" | grep -E "${libcxx_symbol_pattern}" | head -n20 || true
    exit 1
  fi

  if printf '%s\n' "${symbol_dump}" | grep -Eq "${gnucxx_symbol_pattern}"; then
    has_gnu_abi=1
  fi

  if hash readelf 2>/dev/null; then
    dynamic_dump="$(readelf -d "${native_path}" 2>/dev/null || true)"
    if printf '%s\n' "${dynamic_dump}" | grep -Eq 'libstdc\+\+\.so\.6'; then
      has_gnu_abi=1
    fi
  fi

  if hash strings 2>/dev/null; then
    string_dump="$(strings "${native_path}" 2>/dev/null || true)"
    if printf '%s\n' "${string_dump}" | grep -Eq 'libc\+\+|libc\+\+abi'; then
      echo "Unexpected libc++ runtime reference in ${native_path}"
      printf '%s\n' "${string_dump}" | grep -E 'libc\+\+|libc\+\+abi' | head -n20 || true
      exit 1
    fi
    if printf '%s\n' "${string_dump}" | grep -Eq 'libstdc\+\+\.so\.6'; then
      has_gnu_abi=1
    fi
  fi

  if [ "${has_gnu_abi}" -eq 0 ]; then
    echo "Could not confirm GNU libstdc++ ABI in ${native_path}"
    exit 1
  fi
}

validate_static_dependency_shape() {
  local native_path="$1"
  local dynamic_dump=""
  local forbidden_pattern='libjemalloc|libsnappy|libbz2|liblz4|libzstd'

  if hash objdump 2>/dev/null; then
    dynamic_dump="$(objdump -p "${native_path}" 2>/dev/null || true)"
  elif hash readelf 2>/dev/null; then
    dynamic_dump="$(readelf -d "${native_path}" 2>/dev/null || true)"
  else
    echo "Neither objdump nor readelf is available to validate runtime deps in ${native_path}"
    exit 1
  fi

  if printf '%s\n' "${dynamic_dump}" | grep -Eqi "${forbidden_pattern}"; then
    echo "Unexpected dynamic runtime dependency in ${native_path}"
    printf '%s\n' "${dynamic_dump}" | grep -Ei "${forbidden_pattern}|NEEDED|INTERP" || true
    exit 1
  fi
}

extract_max_version() {
  local native_path="$1"
  local prefix="$2"
  local dump=""
  local pattern="${prefix}_[0-9]+\\.[0-9]+(\\.[0-9]+)?"

  if hash objdump 2>/dev/null; then
    dump="$(objdump -T "${native_path}" 2>/dev/null || true)"
  elif hash readelf 2>/dev/null; then
    dump="$(readelf -Ws "${native_path}" 2>/dev/null || true)"
  else
    echo ""
    return 0
  fi

  printf '%s\n' "${dump}" | grep -Eo "${pattern}" | sed "s/^${prefix}_//" | sort -Vu | tail -n1
}

validate_max_symbol_version() {
  local native_path="$1"
  local prefix="$2"
  local expected_max="$3"
  local actual_max=""

  [ -n "${expected_max}" ] || return 0

  actual_max="$(extract_max_version "${native_path}" "${prefix}")"
  [ -n "${actual_max}" ] || return 0

  if [ "$(printf '%s\n%s\n' "${expected_max}" "${actual_max}" | sort -V | tail -n1)" != "${expected_max}" ]; then
    echo "${native_path} exceeds configured ${prefix} ceiling: expected <= ${expected_max}, got ${actual_max}"
    exit 1
  fi
}

validate_release_linux_abi_ceiling() {
  local native_path="$1"
  local native_name
  local max_glibc=""
  local max_glibcxx=""
  local max_cxxabi=""

  native_name="$(basename "${native_path}")"
  case "${native_name}" in
    librocksdbjni-linux32.so)
      max_glibc='2.17'
      max_glibcxx='3.4.29'
      max_cxxabi='1.3.13'
      ;;
    librocksdbjni-linux64.so)
      max_glibc='2.17'
      max_glibcxx='3.4.32'
      max_cxxabi='1.3.15'
      ;;
    librocksdbjni-linux-aarch64.so)
      max_glibc='2.17'
      max_glibcxx='3.4.29'
      max_cxxabi='1.3.13'
      ;;
    librocksdbjni-linux-ppc64le.so)
      max_glibc='2.35'
      max_glibcxx='3.4.32'
      max_cxxabi='1.3.15'
      ;;
    librocksdbjni-linux-s390x.so)
      max_glibc='2.17'
      max_glibcxx='3.4.29'
      max_cxxabi='1.3.13'
      ;;
    librocksdbjni-linux-riscv64.so)
      max_glibc='2.30'
      max_glibcxx='3.4.29'
      max_cxxabi='1.3.13'
      ;;
    *)
      return 0
      ;;
  esac

  validate_max_symbol_version "${native_path}" GLIBC "${max_glibc}"
  validate_max_symbol_version "${native_path}" GLIBCXX "${max_glibcxx}"
  validate_max_symbol_version "${native_path}" CXXABI "${max_cxxabi}"
}

validate_musl_loader_and_deps() {
  local native_path="$1"
  local native_name
  local expected_loader=""
  local dynamic_dump=""
  local string_dump=""

  native_name="$(basename "${native_path}")"
  case "${native_name}" in
    librocksdbjni-linux32-musl.so)
      expected_loader='libc.musl-x86.so.1'
      ;;
    librocksdbjni-linux64-musl.so)
      expected_loader='libc.musl-x86_64.so.1'
      ;;
    librocksdbjni-linux-aarch64-musl.so)
      expected_loader='libc.musl-aarch64.so.1'
      ;;
    librocksdbjni-linux-ppc64le-musl.so)
      expected_loader='libc.musl-ppc64le.so.1'
      ;;
    librocksdbjni-linux-s390x-musl.so)
      expected_loader='libc.musl-s390x.so.1'
      ;;
    *)
      return 0
      ;;
  esac

  if hash objdump 2>/dev/null; then
    dynamic_dump="$(objdump -p "${native_path}" 2>/dev/null || true)"
  elif hash readelf 2>/dev/null; then
    dynamic_dump="$(readelf -d "${native_path}" 2>/dev/null || true)"
  fi

  if [ -n "${dynamic_dump}" ]; then
    if ! printf '%s\n' "${dynamic_dump}" | grep -Eq "${expected_loader}"; then
      echo "Unexpected musl loader dependency in ${native_path}; expected ${expected_loader}"
      printf '%s\n' "${dynamic_dump}" | grep -E 'NEEDED|INTERP' || true
      exit 1
    fi
    if ! printf '%s\n' "${dynamic_dump}" | grep -Eq 'libstdc\+\+\.so\.6'; then
      echo "Missing libstdc++.so.6 dependency in ${native_path}"
      exit 1
    fi
    if ! printf '%s\n' "${dynamic_dump}" | grep -Eq 'libgcc_s\.so\.1'; then
      echo "Missing libgcc_s.so.1 dependency in ${native_path}"
      exit 1
    fi
    return 0
  fi

  if hash strings 2>/dev/null; then
    string_dump="$(strings "${native_path}" 2>/dev/null || true)"
    if ! printf '%s\n' "${string_dump}" | grep -Eq "${expected_loader}"; then
      echo "Unexpected musl loader marker in ${native_path}; expected ${expected_loader}"
      exit 1
    fi
    if ! printf '%s\n' "${string_dump}" | grep -Eq 'libstdc\+\+\.so\.6'; then
      echo "Missing libstdc++.so.6 marker in ${native_path}"
      exit 1
    fi
    if ! printf '%s\n' "${string_dump}" | grep -Eq 'libgcc_s\.so\.1'; then
      echo "Missing libgcc_s.so.1 marker in ${native_path}"
      exit 1
    fi
    return 0
  fi

  echo "Neither objdump/readelf nor strings is available to validate musl dependency shape in ${native_path}"
  exit 1
}

validate_native_artifact() {
  local native_path="$1"
  local native_name
  local file_pattern
  local readelf_pattern
  local file_output
  local readelf_machine
  local checked_format=0

  native_name=$(basename "${native_path}")
  case "${native_name}" in
    librocksdbjni-linux32.so|librocksdbjni-linux32-musl.so)
      file_pattern='ELF 32-bit.*Intel 80386'
      readelf_pattern='Intel 80386'
      ;;
    librocksdbjni-linux64.so|librocksdbjni-linux64-musl.so)
      file_pattern='ELF 64-bit.*x86-64'
      readelf_pattern='Advanced Micro Devices X86-64'
      ;;
    librocksdbjni-linux-aarch64.so|librocksdbjni-linux-aarch64-musl.so)
      file_pattern='ELF 64-bit.*ARM aarch64'
      readelf_pattern='AArch64'
      ;;
    librocksdbjni-linux-ppc64le.so|librocksdbjni-linux-ppc64le-musl.so)
      file_pattern='ELF 64-bit.*PowerPC'
      readelf_pattern='PowerPC64'
      ;;
    librocksdbjni-linux-s390x.so|librocksdbjni-linux-s390x-musl.so)
      file_pattern='ELF 64-bit.*IBM S/390'
      readelf_pattern='IBM S/390'
      ;;
    librocksdbjni-linux-riscv64.so|librocksdbjni-linux-riscv64-musl.so)
      file_pattern='ELF 64-bit.*RISC-V'
      readelf_pattern='RISC-V'
      ;;
    *)
      echo "No validation rule for native artifact: ${native_name}"
      exit 1
      ;;
  esac

  if hash file 2>/dev/null; then
    file_output=$(LC_ALL=C file -b "${native_path}")
    if ! printf '%s\n' "${file_output}" | grep -Eq "${file_pattern}"; then
      echo "Unexpected native format for ${native_name}: ${file_output}"
      exit 1
    fi
    checked_format=1
  fi

  if hash readelf 2>/dev/null; then
    readelf_machine=$(LC_ALL=C readelf -h "${native_path}" | awk -F: '/Machine:/{sub(/^ +/, "", $2); print $2; exit}')
    if ! printf '%s\n' "${readelf_machine}" | grep -Eq "${readelf_pattern}"; then
      echo "Unexpected ELF machine for ${native_name}: ${readelf_machine}"
      exit 1
    fi
    checked_format=1
  fi

  if [ "${checked_format}" -eq 0 ]; then
    echo "Neither file nor readelf is available to validate ${native_name}"
    exit 1
  fi
}

validate_classifier_jar() {
  local jar_path="$1"
  local native_name="$2"

  if ! jar tf "${jar_path}" | grep -Fxq "${native_name}"; then
    echo "Jar ${jar_path} does not contain ${native_name}"
    exit 1
  fi
}

# Use scl devtoolset if available
if hash scl 2>/dev/null; then
  DEVTOOLSET=$(scl --list | tr ' ' '\n' | grep -E '^devtoolset-[0-9]+$' | sort -V | tail -1)
  if [ -n "${DEVTOOLSET}" ]; then
    echo "Using ${DEVTOOLSET}"
    scl enable "${DEVTOOLSET}" 'make clean-not-downloaded'
    scl enable "${DEVTOOLSET}" "make -j${J} rocksdbjavastatic"
  else
    echo "Could not find devtoolset, falling back to system toolchain"
    make clean-not-downloaded
    make -j"${J}" rocksdbjavastatic
  fi
else
  make clean-not-downloaded
  make -j"${J}" rocksdbjavastatic
fi

shopt -s nullglob
native_artifacts=(java/target/librocksdbjni-linux*.so)

if [ "${#native_artifacts[@]}" -eq 0 ]; then
  echo "No Linux JNI native artifacts were produced"
  exit 1
fi

for native_artifact in "${native_artifacts[@]}"; do
  rewrite_musl_libc_needed "${native_artifact}"
  validate_native_artifact "${native_artifact}"
  validate_no_sanitizer_refs "${native_artifact}"
  validate_gnu_cxx_abi "${native_artifact}"
  validate_static_dependency_shape "${native_artifact}"
  validate_release_linux_abi_ceiling "${native_artifact}"
  validate_musl_loader_and_deps "${native_artifact}"
done

if [ "${ROCKSDB_COPY_JARS:-1}" = "1" ]; then
  classifier_jars=(java/target/rocksdbjni-*-linux*.jar)
  if [ "${#classifier_jars[@]}" -eq 0 ]; then
    echo "Expected Linux classifier jars, but none were produced"
    exit 1
  fi

  for classifier_jar in "${classifier_jars[@]}"; do
    for native_artifact in "${native_artifacts[@]}"; do
      validate_classifier_jar "${classifier_jar}" "$(basename "${native_artifact}")"
    done
  done

  cp java/target/librocksdbjni-linux*.so java/target/rocksdbjni-*-linux*.jar java/target/rocksdbjni-*-linux*.jar.sha1 /rocksdb-java-target
else
  cp java/target/librocksdbjni-linux*.so /rocksdb-java-target
fi
