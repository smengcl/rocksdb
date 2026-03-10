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

# just in-case this is run outside Docker
mkdir -p /rocksdb-local-build

rm -rf /rocksdb-local-build/*
cp -r /rocksdb-host/* /rocksdb-local-build
cd /rocksdb-local-build

# Optional cross-compilation mode for building Linux JNI artifacts from an arm64 host.
if [ -n "${ROCKSDB_CROSS_TRIPLE}" ]; then
  case "${ROCKSDB_CROSS_TRIPLE}" in
    x86-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=x86
      CROSS_TARGET_ARCHITECTURE=x86
      CROSS_MACHINE=x86
      CROSS_ARCH=32
      CROSS_JNI_LIBC=
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    x86-linux-musl)
      CROSS_SYSTEM_PROCESSOR=x86
      CROSS_TARGET_ARCHITECTURE=x86
      CROSS_MACHINE=x86
      CROSS_ARCH=32
      CROSS_JNI_LIBC=musl
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    x86_64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=x86_64
      CROSS_TARGET_ARCHITECTURE=x86_64
      CROSS_MACHINE=x86_64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    x86_64-linux-musl)
      CROSS_SYSTEM_PROCESSOR=x86_64
      CROSS_TARGET_ARCHITECTURE=x86_64
      CROSS_MACHINE=x86_64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    powerpc64le-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=ppc64le
      CROSS_TARGET_ARCHITECTURE=ppc64le
      CROSS_MACHINE=ppc64le
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    powerpc64le-linux-musl)
      CROSS_SYSTEM_PROCESSOR=ppc64le
      CROSS_TARGET_ARCHITECTURE=ppc64le
      CROSS_MACHINE=ppc64le
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    s390x-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=s390x
      CROSS_TARGET_ARCHITECTURE=s390x
      CROSS_MACHINE=s390x
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      CROSS_ZIG_CPU=arch8
      CROSS_ZIG_STRIP_MARCH=
      ;;
    s390x-linux-musl)
      CROSS_SYSTEM_PROCESSOR=s390x
      CROSS_TARGET_ARCHITECTURE=s390x
      CROSS_MACHINE=s390x
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      CROSS_ZIG_CPU=arch8
      CROSS_ZIG_STRIP_MARCH=
      ;;
    riscv64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=riscv64
      CROSS_TARGET_ARCHITECTURE=riscv64
      CROSS_MACHINE=riscv64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      CROSS_ZIG_CPU=generic_rv64+d+f+c+m+a
      CROSS_ZIG_STRIP_MARCH=rv64gc
      ;;
    riscv64-linux-musl)
      CROSS_SYSTEM_PROCESSOR=riscv64
      CROSS_TARGET_ARCHITECTURE=riscv64
      CROSS_MACHINE=riscv64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      CROSS_ZIG_CPU=generic_rv64+d+f+c+m+a
      CROSS_ZIG_STRIP_MARCH=rv64gc
      ;;
    *)
      echo "Unsupported ROCKSDB_CROSS_TRIPLE: ${ROCKSDB_CROSS_TRIPLE}"
      exit 1
      ;;
  esac

  echo "Configuring cross-compile toolchain for ${ROCKSDB_CROSS_TRIPLE}"

  ROCKSDB_ZIG_VERSION="${ROCKSDB_ZIG_VERSION:-0.15.2}"
  ROCKSDB_ZIG_ROOT="/tmp/zig-aarch64-linux-${ROCKSDB_ZIG_VERSION}"
  ROCKSDB_ZIG_URL="${ROCKSDB_ZIG_URL:-https://ziglang.org/download/${ROCKSDB_ZIG_VERSION}/zig-aarch64-linux-${ROCKSDB_ZIG_VERSION}.tar.xz}"

  if [ ! -x "${ROCKSDB_ZIG_ROOT}/zig" ]; then
    if hash apk 2>/dev/null; then
      apk add --no-cache curl xz
    else
      echo "curl and xz are required to fetch Zig ${ROCKSDB_ZIG_VERSION}"
      exit 1
    fi

    curl -fsSL "${ROCKSDB_ZIG_URL}" -o "/tmp/zig-aarch64-linux-${ROCKSDB_ZIG_VERSION}.tar.xz"
    tar -C /tmp -xf "/tmp/zig-aarch64-linux-${ROCKSDB_ZIG_VERSION}.tar.xz"
  fi

  CROSS_WRAPPERS_DIR=/tmp/rocksdb-zig-cross
  mkdir -p "${CROSS_WRAPPERS_DIR}"

  cat > "${CROSS_WRAPPERS_DIR}/cc" <<EOF
#!/usr/bin/env bash
strip_march="${CROSS_ZIG_STRIP_MARCH}"
args=()
for arg in "\$@"; do
  if [ -n "\${strip_march}" ] && { [ "\$arg" = "-march=\${strip_march}" ] || [ "\$arg" = "-mcpu=\${strip_march}" ]; }; then
    continue
  fi
  args+=("\$arg")
done
exec "${ROCKSDB_ZIG_ROOT}/zig" cc -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} "\${args[@]}"
EOF

  cat > "${CROSS_WRAPPERS_DIR}/cxx" <<EOF
#!/usr/bin/env bash
strip_march="${CROSS_ZIG_STRIP_MARCH}"
args=()
for arg in "\$@"; do
  if [ -n "\${strip_march}" ] && { [ "\$arg" = "-march=\${strip_march}" ] || [ "\$arg" = "-mcpu=\${strip_march}" ]; }; then
    continue
  fi
  args+=("\$arg")
done
exec "${ROCKSDB_ZIG_ROOT}/zig" c++ -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} "\${args[@]}"
EOF

  chmod +x "${CROSS_WRAPPERS_DIR}/cc" "${CROSS_WRAPPERS_DIR}/cxx"
  export CC="${CROSS_WRAPPERS_DIR}/cc"
  export CXX="${CROSS_WRAPPERS_DIR}/cxx"
  export TARGET_ARCHITECTURE="${CROSS_TARGET_ARCHITECTURE}"
  export MACHINE="${CROSS_MACHINE}"
  export ARCH="${CROSS_ARCH}"
  export ROCKSDB_CROSS_LIBC="${CROSS_JNI_LIBC:-gnu}"
  if [ -n "${CROSS_JNI_LIBC}" ]; then
    export JNI_LIBC="${CROSS_JNI_LIBC}"
  else
    unset JNI_LIBC
  fi
  export PLATFORM_CMAKE_FLAGS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=${CROSS_SYSTEM_PROCESSOR} -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
fi

# Keep the historical GCC workaround for regular builds, and use clang-safe flags for zig cross builds.
if [ -z "${EXTRA_CXXFLAGS}" ]; then
  EXTRA_CXXFLAGS=""
fi
if [ -z "${EXTRA_CFLAGS}" ]; then
  EXTRA_CFLAGS=""
fi

if [ -n "${ROCKSDB_CROSS_TRIPLE}" ]; then
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -Wno-error=unknown-warning-option -Wno-unknown-warning-option"
  EXTRA_CFLAGS="${EXTRA_CFLAGS} -Wno-error=unknown-warning-option -Wno-unknown-warning-option"
else
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -Wno-error=restrict"
fi

export EXTRA_CXXFLAGS
export EXTRA_CFLAGS

validate_native_artifact() {
  local native_path="$1"
  local native_name
  local file_output
  local readelf_machine
  local file_pattern
  local readelf_pattern

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

  file_output=$(LC_ALL=C file -b "${native_path}")
  if ! printf '%s\n' "${file_output}" | grep -Eq "${file_pattern}"; then
    echo "Unexpected native format for ${native_name}: ${file_output}"
    exit 1
  fi

  if hash readelf 2>/dev/null; then
    readelf_machine=$(LC_ALL=C readelf -h "${native_path}" | awk -F: '/Machine:/{sub(/^ +/, "", $2); print $2; exit}')
    if ! printf '%s\n' "${readelf_machine}" | grep -Eq "${readelf_pattern}"; then
      echo "Unexpected ELF machine for ${native_name}: ${readelf_machine}"
      exit 1
    fi
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
  validate_native_artifact "${native_artifact}"
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
