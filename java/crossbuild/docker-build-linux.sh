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

# Optional cross-compilation mode, currently used for arm64 host building x86_64-musl artifacts.
if [ -n "${ROCKSDB_CROSS_TRIPLE}" ]; then
  case "${ROCKSDB_CROSS_TRIPLE}" in
    x86_64-linux-musl)
      echo "Configuring cross-compile toolchain for ${ROCKSDB_CROSS_TRIPLE}"

      if ! hash zig 2>/dev/null; then
        if hash apk 2>/dev/null; then
          apk add --no-cache zig
        else
          echo "zig is required for ROCKSDB_CROSS_TRIPLE=${ROCKSDB_CROSS_TRIPLE}"
          exit 1
        fi
      fi

      CROSS_WRAPPERS_DIR=/tmp/rocksdb-zig-cross
      mkdir -p "${CROSS_WRAPPERS_DIR}"

      cat > "${CROSS_WRAPPERS_DIR}/cc" <<'EOF'
#!/usr/bin/env sh
exec zig cc -target x86_64-linux-musl "$@"
EOF

      cat > "${CROSS_WRAPPERS_DIR}/cxx" <<'EOF'
#!/usr/bin/env sh
exec zig c++ -target x86_64-linux-musl "$@"
EOF

      chmod +x "${CROSS_WRAPPERS_DIR}/cc" "${CROSS_WRAPPERS_DIR}/cxx"
      export CC="${CROSS_WRAPPERS_DIR}/cc"
      export CXX="${CROSS_WRAPPERS_DIR}/cxx"
      export TARGET_ARCHITECTURE=x86_64
      export MACHINE=x86_64
      export JNI_LIBC=musl
      export PLATFORM_CMAKE_FLAGS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
      ;;
    *)
      echo "Unsupported ROCKSDB_CROSS_TRIPLE: ${ROCKSDB_CROSS_TRIPLE}"
      exit 1
      ;;
  esac
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

cp java/target/librocksdbjni-linux*.so java/target/rocksdbjni-*-linux*.jar java/target/rocksdbjni-*-linux*.jar.sha1 /rocksdb-java-target
