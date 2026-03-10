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

if [ "${ROCKSDB_COPY_JARS:-1}" = "1" ]; then
  cp java/target/librocksdbjni-linux*.so java/target/rocksdbjni-*-linux*.jar java/target/rocksdbjni-*-linux*.jar.sha1 /rocksdb-java-target
else
  cp java/target/librocksdbjni-linux*.so /rocksdb-java-target
fi
