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

# Release artifact builds must never pick up sanitizer instrumentation.
unset COMPILE_WITH_ASAN COMPILE_WITH_TSAN COMPILE_WITH_UBSAN
unset ASAN_OPTIONS TSAN_OPTIONS UBSAN_OPTIONS

# just in-case this is run outside Docker
mkdir -p /rocksdb-local-build

# Clean the persistent build volume fully, including dot-directories such as
# `.cache`, so stale Zig cache entries cannot leak across runs.
find /rocksdb-local-build -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -r /rocksdb-host/* /rocksdb-local-build
cd /rocksdb-local-build

# Keep tool caches on the writable build volume rather than the container's
# default home/cache locations, which may be mounted read-only.
export HOME=/rocksdb-local-build
export XDG_CACHE_HOME=/rocksdb-local-build/.cache
mkdir -p "${XDG_CACHE_HOME}"

ROCKSDB_X86_64_GNU_GLIBC_MAX_VERSION=2.30
ROCKSDB_X86_64_GNU_GLIBCXX_MAX_VERSION=3.4.19

validate_x86_64_gnu_runtime_layout() {
  local toolchain_root="$1"
  local required_paths=(
    "compat/include/sys/single_threaded.h"
    "usr/x86_64-linux-gnu/include/c++/12/algorithm"
    "usr/x86_64-linux-gnu/include/c++/12/x86_64-linux-gnu/bits/c++config.h"
    "usr/lib/gcc-cross/x86_64-linux-gnu/12/include/cpuid.h"
    "usr/lib/gcc-cross/x86_64-linux-gnu/12/libstdc++.so"
    "usr/lib/gcc-cross/x86_64-linux-gnu/12/libgcc_s.so"
    "usr/x86_64-linux-gnu/lib/libstdc++.so.6"
    "usr/x86_64-linux-gnu/lib/libgcc_s.so.1"
  )
  local required_path

  for required_path in "${required_paths[@]}"; do
    if [ ! -e "${toolchain_root}/${required_path}" ]; then
      echo "Missing GNU C++ runtime path: ${toolchain_root}/${required_path}"
      return 1
    fi
  done

  return 0
}

bootstrap_x86_64_gnu_runtime() {
  local toolchain_root="${XDG_CACHE_HOME}/gnu-toolchains/debian-bookworm-gcc12-x86_64-linux-gnu"
  local toolchain_parent
  local sentinel="${toolchain_root}/.complete"
  local package_base_url="https://deb.debian.org/debian/pool/main/g/gcc-12-cross"
  local package_names=(
    "libstdc++-12-dev-amd64-cross_12.2.0-14cross1_all.deb"
    "libstdc++6-amd64-cross_12.2.0-14cross1_all.deb"
    "libgcc-12-dev-amd64-cross_12.2.0-14cross1_all.deb"
    "libgcc-s1-amd64-cross_12.2.0-14cross1_all.deb"
  )
  local package_name
  local temp_root
  local package_dir
  local package_path
  local data_archive

  if [ -f "${sentinel}" ] && validate_x86_64_gnu_runtime_layout "${toolchain_root}"; then
    printf '%s\n' "${toolchain_root}"
    return 0
  fi

  toolchain_parent=$(dirname "${toolchain_root}")
  mkdir -p "${toolchain_parent}"
  temp_root=$(mktemp -d "${toolchain_parent}/debian-bookworm-gcc12-x86_64-linux-gnu.tmp.XXXXXX")
  package_dir="${temp_root}/packages"
  mkdir -p "${package_dir}"

  for package_name in "${package_names[@]}"; do
    package_path="${package_dir}/${package_name}"
    curl -fsSL "${package_base_url}/${package_name}" -o "${package_path}"
    data_archive=$(ar t "${package_path}" | awk '/^data\.tar\./ { print; exit }')
    if [ -z "${data_archive}" ]; then
      echo "Could not locate data archive in ${package_path}"
      rm -rf "${temp_root}"
      exit 1
    fi
    case "${data_archive}" in
      *.tar.xz)
        ar p "${package_path}" "${data_archive}" | tar -C "${temp_root}" -xJf -
        ;;
      *.tar.gz)
        ar p "${package_path}" "${data_archive}" | tar -C "${temp_root}" -xzf -
        ;;
      *.tar.bz2)
        ar p "${package_path}" "${data_archive}" | tar -C "${temp_root}" -xjf -
        ;;
      *)
        echo "Unsupported archive payload ${data_archive} in ${package_path}"
        rm -rf "${temp_root}"
        exit 1
        ;;
    esac
  done

  mkdir -p "${temp_root}/compat/include/sys"
  cat > "${temp_root}/compat/include/sys/single_threaded.h" <<'EOF'
#ifndef ROCKSDB_GNU_COMPAT_SYS_SINGLE_THREADED_H
#define ROCKSDB_GNU_COMPAT_SYS_SINGLE_THREADED_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Bookworm libstdc++ opportunistically uses __libc_single_threaded when the
 * header exists. Declare it weak so binaries remain loadable on glibc floors
 * predating 2.32, where the symbol is absent and the runtime will conservatively
 * behave as multi-threaded.
 */
extern char __libc_single_threaded __attribute__((__weak__));

#ifdef __cplusplus
}
#endif

#endif
EOF

  if ! validate_x86_64_gnu_runtime_layout "${temp_root}"; then
    rm -rf "${temp_root}"
    exit 1
  fi

  {
    printf 'debian-bookworm-gcc12-x86_64-linux-gnu\n'
    for package_name in "${package_names[@]}"; do
      printf '%s\n' "${package_name}"
    done
  } > "${temp_root}/.complete"

  rm -rf "${toolchain_root}"
  mv "${temp_root}" "${toolchain_root}"
  printf '%s\n' "${toolchain_root}"
}

version_le() {
  local lhs="$1"
  local rhs="$2"

  [ "$(printf '%s\n%s\n' "${lhs}" "${rhs}" | sort -V | tail -n1)" = "${rhs}" ]
}

# Optional cross-compilation mode for building Linux JNI artifacts via Zig using
# explicit *-linux-gnu and *-linux-musl target triples.
if [ -n "${ROCKSDB_CROSS_TRIPLE}" ]; then
  case "${ROCKSDB_CROSS_TRIPLE}" in
    aarch64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=aarch64
      CROSS_TARGET_ARCHITECTURE=aarch64
      CROSS_MACHINE=aarch64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
    aarch64-linux-musl)
      CROSS_SYSTEM_PROCESSOR=aarch64
      CROSS_TARGET_ARCHITECTURE=aarch64
      CROSS_MACHINE=aarch64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      CROSS_ZIG_CPU=
      CROSS_ZIG_STRIP_MARCH=
      ;;
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
  export ZIG_GLOBAL_CACHE_DIR="${XDG_CACHE_HOME}/zig/global"
  export ZIG_LOCAL_CACHE_DIR="${XDG_CACHE_HOME}/zig/local"
  mkdir -p "${ZIG_GLOBAL_CACHE_DIR}" "${ZIG_LOCAL_CACHE_DIR}"
  case "$(uname -m)" in
    aarch64|arm64)
      ROCKSDB_ZIG_HOST_ARCH=aarch64
      ;;
    x86_64|amd64)
      ROCKSDB_ZIG_HOST_ARCH=x86_64
      ;;
    *)
      echo "Unsupported Zig host architecture: $(uname -m)"
      exit 1
      ;;
  esac
  ROCKSDB_ZIG_ROOT="/tmp/zig-${ROCKSDB_ZIG_HOST_ARCH}-linux-${ROCKSDB_ZIG_VERSION}"
  ROCKSDB_ZIG_URL="${ROCKSDB_ZIG_URL:-https://ziglang.org/download/${ROCKSDB_ZIG_VERSION}/zig-${ROCKSDB_ZIG_HOST_ARCH}-linux-${ROCKSDB_ZIG_VERSION}.tar.xz}"

  if [ ! -x "${ROCKSDB_ZIG_ROOT}/zig" ]; then
    if hash apk 2>/dev/null; then
      apk add --no-cache curl xz elfutils
    else
      echo "curl, xz, and elfutils are required to fetch Zig ${ROCKSDB_ZIG_VERSION}"
      exit 1
    fi

    curl -fsSL "${ROCKSDB_ZIG_URL}" -o "/tmp/zig-${ROCKSDB_ZIG_HOST_ARCH}-linux-${ROCKSDB_ZIG_VERSION}.tar.xz"
    tar -C /tmp -xf "/tmp/zig-${ROCKSDB_ZIG_HOST_ARCH}-linux-${ROCKSDB_ZIG_VERSION}.tar.xz"
  fi

  CROSS_WRAPPERS_DIR=/tmp/rocksdb-zig-cross
  CROSS_GNU_CXX_TOOLCHAIN_ROOT=
  if [ "${ROCKSDB_CROSS_TRIPLE}" = "x86_64-linux-gnu" ]; then
    CROSS_GNU_CXX_TOOLCHAIN_ROOT=$(bootstrap_x86_64_gnu_runtime)
  fi
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
gnu_toolchain_root="${CROSS_GNU_CXX_TOOLCHAIN_ROOT}"
args=()
link_mode=1
has_source_inputs=0
for arg in "\$@"; do
  if [ -n "\${strip_march}" ] && { [ "\$arg" = "-march=\${strip_march}" ] || [ "\$arg" = "-mcpu=\${strip_march}" ]; }; then
    continue
  fi
  case "\$arg" in
    -c|-E|-S|-M|-MM|-fsyntax-only)
      link_mode=0
      ;;
    -|*.c|*.cc|*.cp|*.cpp|*.cxx|*.C|*.s|*.S|*.m|*.mm)
      has_source_inputs=1
      ;;
  esac
  args+=("\$arg")
done
if [ -n "\${gnu_toolchain_root}" ]; then
  gnu_compile_args=(
    -nostdinc++
    "--gcc-toolchain=\${gnu_toolchain_root}/usr"
    -I "\${gnu_toolchain_root}/compat/include"
    -I "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/include/c++/12"
    -I "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/include/c++/12/x86_64-linux-gnu"
    -I "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/include/c++/12/backward"
    -isystem "\${gnu_toolchain_root}/usr/lib/gcc-cross/x86_64-linux-gnu/12/include"
  )
  gnu_link_args=(
    -L "\${gnu_toolchain_root}/usr/lib/gcc-cross/x86_64-linux-gnu/12"
    -L "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/lib"
  )
  if [ "\${link_mode}" = "1" ]; then
    zig_link_cmd=("${ROCKSDB_ZIG_ROOT}/zig" cc -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} "\${gnu_link_args[@]}" "\${args[@]}" -lstdc++ -lgcc_s -lc -lm -ldl -lpthread -lrt)
    if [ "\${has_source_inputs}" = "1" ]; then
      exec "\${zig_link_cmd[@]}"
    fi
    probe_source=\$(mktemp /tmp/rocksdb-zig-link-probe.XXXXXX.c)
    probe_output=\$(mktemp /tmp/rocksdb-zig-link-probe.XXXXXX.so)
    cat > "\${probe_source}" <<'PROBE_EOF'
int rocksdb_zig_link_probe(void) {
  return 0;
}
PROBE_EOF
    resolve_probe_runtime_path() {
      local runtime_path="\$1"
      local runtime_candidate
      local runtime_basename
      local runtime_fallback
      if [ -f "\${runtime_path}" ]; then
        printf '%s\n' "\${runtime_path}"
        return 0
      fi
      if [[ "\${runtime_path}" != /* ]]; then
        runtime_candidate="\${PWD}/\${runtime_path}"
        if [ -f "\${runtime_candidate}" ]; then
          printf '%s\n' "\${runtime_candidate}"
          return 0
        fi
        runtime_candidate="${XDG_CACHE_HOME}/\${runtime_path#.cache/}"
        if [ -f "\${runtime_candidate}" ]; then
          printf '%s\n' "\${runtime_candidate}"
          return 0
        fi
        runtime_candidate="\${ZIG_GLOBAL_CACHE_DIR}/\${runtime_path#*.cache/zig/global/}"
        if [ -f "\${runtime_candidate}" ]; then
          printf '%s\n' "\${runtime_candidate}"
          return 0
        fi
        runtime_candidate="\${ZIG_LOCAL_CACHE_DIR}/\${runtime_path#*.cache/zig/local/}"
        if [ -f "\${runtime_candidate}" ]; then
          printf '%s\n' "\${runtime_candidate}"
          return 0
        fi
      fi
      runtime_basename=\$(basename "\${runtime_path}")
      runtime_fallback=\$(find "\${PWD}/.cache/zig" "${XDG_CACHE_HOME}/zig" -type f -name "\${runtime_basename}" 2>/dev/null | head -n1)
      if [ -n "\${runtime_fallback}" ]; then
        printf '%s\n' "\${runtime_fallback}"
        return 0
      fi
      return 1
    }
    find_probe_runtime_by_basename() {
      local runtime_basename="\$1"
      local runtime_fallback
      runtime_fallback=\$(find "${XDG_CACHE_HOME}/zig" -type f -name "\${runtime_basename}" 2>/dev/null | head -n1)
      if [ -n "\${runtime_fallback}" ]; then
        printf '%s\n' "\${runtime_fallback}"
        return 0
      fi
      return 1
    }
    materialize_probe_runtime_path() {
      local runtime_path="\$1"
      local runtime_fallback
      if [ -f "\${runtime_path}" ]; then
        printf '%s\n' "\${runtime_path}"
        return 0
      fi
      runtime_fallback=\$(find_probe_runtime_by_basename "\$(basename "\${runtime_path}")" || true)
      if [ -n "\${runtime_fallback}" ]; then
        mkdir -p "\$(dirname "\${runtime_path}")"
        cp "\${runtime_fallback}" "\${runtime_path}"
        printf '%s\n' "\${runtime_path}"
        return 0
      fi
      return 1
    }
    probe_ld_line=
    probe_dynamic_linker=/lib64/ld-linux-x86-64.so.2
    probe_libubsan=
    probe_libc_nonshared=
    probe_libcompiler_rt=
    probe_glibc_libs=()
    probe_resolution_error=
    probe_resolved_ok=0
    for _ in 1 2 3 4 5; do
      probe_log=\$(mktemp)
      "${ROCKSDB_ZIG_ROOT}/zig" cc -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} -shared -fPIC "\${probe_source}" -o "\${probe_output}" -v >"\${probe_log}" 2>&1
      probe_ld_line=\$(grep -E '^ld\\.lld ' "\${probe_log}" | tail -n1)
      rm -f "\${probe_log}"
      probe_libubsan=\$(find_probe_runtime_by_basename libubsan_rt.a || true)
      probe_libc_nonshared=\$(find_probe_runtime_by_basename libc_nonshared.a || true)
      probe_libcompiler_rt=\$(find_probe_runtime_by_basename libcompiler_rt.a || true)
      probe_glibc_dir=\$(dirname "\$(find_probe_runtime_by_basename libc.so.6 || true)")
      if [ -n "\${probe_glibc_dir}" ] && [ "\${probe_glibc_dir}" != "." ]; then
        probe_glibc_libs=(
          "\${probe_glibc_dir}/libm.so.6"
          "\${probe_glibc_dir}/libpthread.so.0"
          "\${probe_glibc_dir}/libc.so.6"
          "\${probe_glibc_dir}/libdl.so.2"
          "\${probe_glibc_dir}/librt.so.1"
          "\${probe_glibc_dir}/libld.so.2"
          "\${probe_glibc_dir}/libutil.so.1"
          "\${probe_glibc_dir}/libresolv.so.2"
        )
      else
        probe_glibc_libs=()
      fi
      if [ -n "\${probe_libc_nonshared}" ] && [ -n "\${probe_libcompiler_rt}" ] && [ "\${#probe_glibc_libs[@]}" -gt 0 ]; then
        probe_resolved_ok=1
        break
      fi
      probe_resolution_error="Missing libc_nonshared.a"
      sleep 1
    done
    rm -f "\${probe_source}" "\${probe_output}"
    if [ "\${probe_resolved_ok}" != "1" ]; then
      echo "\${probe_resolution_error:-Could not resolve Zig runtime inputs}" >&2
      echo "\${probe_ld_line}" >&2
      exit 1
    fi

    direct_link_args=()
    next_link_arg=
    for arg in "\${args[@]}"; do
      if [ -n "\${next_link_arg}" ]; then
        direct_link_args+=("\${arg}")
        next_link_arg=
        continue
      fi
      case "\${arg}" in
        -o|-L|-u|-rpath|-soname)
          direct_link_args+=("\${arg}")
          next_link_arg=1
          ;;
        -Wl,*)
          IFS=',' read -r -a wl_parts <<< "\${arg#-Wl,}"
          direct_link_args+=("\${wl_parts[@]}")
          ;;
        *.o|*.a|*.so|*.so.*)
          direct_link_args+=("\${arg}")
          ;;
        -lstdc++|-lc++|-lc++abi|-lgcc|-lgcc_s|-lc|-lm|-ldl|-lpthread|-lrt)
          ;;
        -l*)
          direct_link_args+=("\${arg}")
          ;;
        -shared|-fPIC)
          ;;
      esac
    done

    link_output=\$(mktemp)
    direct_link_cmd=(
      "${ROCKSDB_ZIG_ROOT}/zig" ld.lld
      --error-limit=0
      -mllvm
      -float-abi=hard
      --build-id=none
      --image-base=0
      --eh-frame-hdr
      -znow
      -m
      elf_x86_64
      -shared
      "\${direct_link_args[@]}"
      -dynamic-linker
      "\${probe_dynamic_linker}"
      --no-undefined-version
    )
    if [ -n "\${probe_libubsan}" ]; then
      direct_link_cmd+=("\${probe_libubsan}")
    fi
    direct_link_cmd+=(
      --as-needed
      "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/lib/libstdc++.so.6"
      "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/lib/libgcc_s.so.1"
      "\${probe_glibc_libs[@]}"
      "\${probe_libc_nonshared}"
      "\${probe_libcompiler_rt}"
    )
    if ! "\${direct_link_cmd[@]}" >"\${link_output}" 2>&1; then
      cat "\${link_output}" >&2
      rm -f "\${link_output}"
      exit 1
    fi
    rm -f "\${link_output}"
    exit 0
  fi
  exec "${ROCKSDB_ZIG_ROOT}/zig" c++ -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} "\${gnu_compile_args[@]}" "\${args[@]}"
fi
exec "${ROCKSDB_ZIG_ROOT}/zig" c++ -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} "\${args[@]}"
EOF

  cat > "${CROSS_WRAPPERS_DIR}/cxx-link" <<EOF
#!/usr/bin/env bash
strip_march="${CROSS_ZIG_STRIP_MARCH}"
gnu_toolchain_root="${CROSS_GNU_CXX_TOOLCHAIN_ROOT}"
args=()
for arg in "\$@"; do
  if [ -n "\${strip_march}" ] && { [ "\$arg" = "-march=\${strip_march}" ] || [ "\$arg" = "-mcpu=\${strip_march}" ]; }; then
    continue
  fi
  args+=("\$arg")
done

direct_link_args=()
next_link_arg=
for arg in "\${args[@]}"; do
  if [ -n "\${next_link_arg}" ]; then
    direct_link_args+=("\${arg}")
    next_link_arg=
    continue
  fi
  case "\${arg}" in
    -o|-L|-u|-rpath|-soname)
      direct_link_args+=("\${arg}")
      next_link_arg=1
      ;;
    -Wl,*)
      IFS=',' read -r -a wl_parts <<< "\${arg#-Wl,}"
      direct_link_args+=("\${wl_parts[@]}")
      ;;
    *.o|*.a|*.so|*.so.*)
      direct_link_args+=("\${arg}")
      ;;
    -lstdc++|-lc++|-lc++abi|-lgcc|-lgcc_s|-lc|-lm|-ldl|-lpthread|-lrt)
      ;;
    -l*)
      direct_link_args+=("\${arg}")
      ;;
    -shared|-fPIC)
      ;;
  esac
done

probe_source=\$(mktemp /tmp/rocksdb-zig-link-probe.XXXXXX.c)
probe_output=\$(mktemp /tmp/rocksdb-zig-link-probe.XXXXXX.so)
probe_cache_root=\$(mktemp -d /tmp/rocksdb-zig-link-cache.XXXXXX)
probe_global_cache_dir="\${probe_cache_root}/global"
probe_local_cache_dir="\${probe_cache_root}/local"
mkdir -p "\${probe_global_cache_dir}" "\${probe_local_cache_dir}"
cleanup_probe_artifacts() {
  rm -f "\${probe_source}" "\${probe_output}"
  rm -rf "\${probe_cache_root}"
}
trap cleanup_probe_artifacts EXIT
cat > "\${probe_source}" <<'PROBE_EOF'
int rocksdb_zig_link_probe(void) {
  return 0;
}
PROBE_EOF

resolve_probe_path() {
  local runtime_path="\$1"
  local runtime_candidate
  if [ -f "\${runtime_path}" ]; then
    printf '%s\n' "\${runtime_path}"
    return 0
  fi
  if [[ "\${runtime_path}" != /* ]]; then
    runtime_candidate="\${PWD}/\${runtime_path}"
    if [ -f "\${runtime_candidate}" ]; then
      printf '%s\n' "\${runtime_candidate}"
      return 0
    fi
    runtime_candidate="\${probe_cache_root}/\${runtime_path#.cache/zig/}"
    if [ -f "\${runtime_candidate}" ]; then
      printf '%s\n' "\${runtime_candidate}"
      return 0
    fi
    runtime_candidate="\${probe_global_cache_dir}/\${runtime_path#*.cache/zig/global/}"
    if [ -f "\${runtime_candidate}" ]; then
      printf '%s\n' "\${runtime_candidate}"
      return 0
    fi
    runtime_candidate="\${probe_local_cache_dir}/\${runtime_path#*.cache/zig/local/}"
    if [ -f "\${runtime_candidate}" ]; then
      printf '%s\n' "\${runtime_candidate}"
      return 0
    fi
  fi
  return 1
}

if [ -z "\${gnu_toolchain_root}" ]; then
  rm -f "\${probe_source}"
  probe_source=\$(mktemp /tmp/rocksdb-zig-link-probe.XXXXXX.cpp)
  cat > "\${probe_source}" <<'PROBE_EOF'
int rocksdb_zig_link_probe() {
  return 0;
}
PROBE_EOF

  probe_ld_line=
  probe_prefix_args=()
  probe_runtime_args=()
  probe_saw_no_undefined=0
  probe_skipped_object=0
  for _ in 1 2 3 4 5; do
    probe_log=\$(mktemp)
    if ! ZIG_GLOBAL_CACHE_DIR="\${probe_global_cache_dir}" ZIG_LOCAL_CACHE_DIR="\${probe_local_cache_dir}" "${ROCKSDB_ZIG_ROOT}/zig" c++ -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} -shared -fPIC "\${probe_source}" -o "\${probe_output}" -v >"\${probe_log}" 2>&1; then
      cat "\${probe_log}" >&2
    fi
    probe_ld_line=\$(grep -E '^ld\\.lld ' "\${probe_log}" | tail -n1)
    rm -f "\${probe_log}"
    if [ -n "\${probe_ld_line}" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "\${probe_ld_line}" ]; then
    echo "Could not capture Zig link line for final link probe" >&2
    exit 1
  fi

  read -r -a probe_parts <<< "\${probe_ld_line}"
  i=1
  while [ "\${i}" -lt "\${#probe_parts[@]}" ]; do
    part="\${probe_parts[\${i}]}"
    if [ "\${part}" = "-o" ]; then
      i=\$((i + 2))
      continue
    fi
    if [ "\${part}" = "--no-undefined-version" ]; then
      probe_prefix_args+=("\${part}")
      probe_saw_no_undefined=1
      i=\$((i + 1))
      continue
    fi
    if [ "\${probe_saw_no_undefined}" = "0" ]; then
      probe_prefix_args+=("\${part}")
      i=\$((i + 1))
      continue
    fi
    case "\${part}" in
      *.o|*.a|*.so|*.so.*)
        if [ "\${probe_skipped_object}" = "0" ]; then
          probe_skipped_object=1
        else
          resolved_part=\$(resolve_probe_path "\${part}" || true)
          if [ -z "\${resolved_part}" ]; then
            echo "Could not resolve probe runtime input: \${part}" >&2
            exit 1
          fi
          probe_runtime_args+=("\${resolved_part}")
        fi
        ;;
      *)
        probe_runtime_args+=("\${part}")
        ;;
    esac
    i=\$((i + 1))
  done

  if [ "\${#probe_runtime_args[@]}" -eq 0 ]; then
    echo "Missing Zig runtime inputs for final link" >&2
    echo "\${probe_ld_line}" >&2
    exit 1
  fi

  link_output=\$(mktemp)
  direct_link_cmd=(
    "${ROCKSDB_ZIG_ROOT}/zig" ld.lld
    "\${probe_prefix_args[@]}"
    "\${direct_link_args[@]}"
    "\${probe_runtime_args[@]}"
  )
  if ! "\${direct_link_cmd[@]}" >"\${link_output}" 2>&1; then
    cat "\${link_output}" >&2
    rm -f "\${link_output}"
    exit 1
  fi
  rm -f "\${link_output}"
  exit 0
fi

probe_libubsan=
probe_libc_nonshared=
probe_libcompiler_rt=
probe_glibc_dir=
for _ in 1 2 3 4 5; do
  probe_log=\$(mktemp)
  if ! ZIG_GLOBAL_CACHE_DIR="\${probe_global_cache_dir}" ZIG_LOCAL_CACHE_DIR="\${probe_local_cache_dir}" "${ROCKSDB_ZIG_ROOT}/zig" cc -target ${ROCKSDB_CROSS_TRIPLE} ${CROSS_ZIG_CPU:+-mcpu=${CROSS_ZIG_CPU}} -shared -fPIC "\${probe_source}" -o "\${probe_output}" -lc -lm -ldl -lpthread -lrt -v >"\${probe_log}" 2>&1; then
    cat "\${probe_log}" >&2
  fi
  rm -f "\${probe_log}"
  probe_libubsan=\$(find "\${probe_cache_root}" -type f -name libubsan_rt.a 2>/dev/null | head -n1)
  probe_libc_nonshared=\$(find "\${probe_cache_root}" -type f -name libc_nonshared.a 2>/dev/null | head -n1)
  probe_libcompiler_rt=\$(find "\${probe_cache_root}" -type f -name libcompiler_rt.a 2>/dev/null | head -n1)
  probe_glibc_dir=\$(dirname "\$(find "\${probe_cache_root}" -type f -name libc.so.6 2>/dev/null | head -n1)")
  if [ -n "\${probe_libc_nonshared}" ] && [ -n "\${probe_libcompiler_rt}" ] && [ -n "\${probe_glibc_dir}" ] && [ "\${probe_glibc_dir}" != "." ]; then
    break
  fi
  sleep 1
done
if [ -z "\${probe_libc_nonshared}" ] || [ -z "\${probe_libcompiler_rt}" ] || [ -z "\${probe_glibc_dir}" ] || [ "\${probe_glibc_dir}" = "." ]; then
  echo "Missing Zig glibc support inputs for final link" >&2
  find "\${probe_cache_root}" -type f \\( -name libc_nonshared.a -o -name libcompiler_rt.a -o -name libc.so.6 -o -name libubsan_rt.a \\) 2>/dev/null >&2 || true
  exit 1
fi

link_output=\$(mktemp)
direct_link_cmd=(
  "${ROCKSDB_ZIG_ROOT}/zig" ld.lld
  --error-limit=0
  -mllvm
  -float-abi=hard
  --build-id=none
  --image-base=0
  --eh-frame-hdr
  -znow
  -m
  elf_x86_64
  -shared
  "\${direct_link_args[@]}"
  -dynamic-linker
  /lib64/ld-linux-x86-64.so.2
  --no-undefined-version
)
if [ -n "\${probe_libubsan}" ]; then
  direct_link_cmd+=("\${probe_libubsan}")
fi
direct_link_cmd+=(
  --as-needed
  "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/lib/libstdc++.so.6"
  "\${gnu_toolchain_root}/usr/x86_64-linux-gnu/lib/libgcc_s.so.1"
  "\${probe_glibc_dir}/libm.so.6"
  "\${probe_glibc_dir}/libpthread.so.0"
  "\${probe_glibc_dir}/libc.so.6"
  "\${probe_glibc_dir}/libdl.so.2"
  "\${probe_glibc_dir}/librt.so.1"
  "\${probe_glibc_dir}/libld.so.2"
  "\${probe_glibc_dir}/libutil.so.1"
  "\${probe_glibc_dir}/libresolv.so.2"
  "\${probe_libc_nonshared}"
  "\${probe_libcompiler_rt}"
)
if ! "\${direct_link_cmd[@]}" >"\${link_output}" 2>&1; then
  cat "\${link_output}" >&2
  rm -f "\${link_output}"
  exit 1
fi
rm -f "\${link_output}"
EOF

  chmod +x "${CROSS_WRAPPERS_DIR}/cc" "${CROSS_WRAPPERS_DIR}/cxx" "${CROSS_WRAPPERS_DIR}/cxx-link"
  export CC="${CROSS_WRAPPERS_DIR}/cc"
  export CXX="${CROSS_WRAPPERS_DIR}/cxx"
  export JAVA_LINK_CXX="${CROSS_WRAPPERS_DIR}/cxx-link"
  export TARGET_ARCHITECTURE="${CROSS_TARGET_ARCHITECTURE}"
  export MACHINE="${CROSS_MACHINE}"
  export ARCH="${CROSS_ARCH}"
  export STRIP=eu-strip
  export STRIPFLAGS=
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
if [ -z "${EXTRA_LDFLAGS}" ]; then
  EXTRA_LDFLAGS=""
fi

EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -fno-sanitize=undefined -fno-sanitize=address -fno-sanitize=thread"
EXTRA_CFLAGS="${EXTRA_CFLAGS} -fno-sanitize=undefined -fno-sanitize=address -fno-sanitize=thread"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS} -fno-sanitize=undefined -fno-sanitize=address -fno-sanitize=thread"

if [ -n "${ROCKSDB_CROSS_TRIPLE}" ]; then
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -Wno-error=unknown-warning-option -Wno-unknown-warning-option"
  EXTRA_CFLAGS="${EXTRA_CFLAGS} -Wno-error=unknown-warning-option -Wno-unknown-warning-option"
  case "${ROCKSDB_CROSS_TRIPLE}" in
    x86-linux-gnu|x86-linux-musl)
      EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -Wno-error=shorten-64-to-32 -Wno-shorten-64-to-32 -Wno-error=sync-alignment"
      EXTRA_CFLAGS="${EXTRA_CFLAGS} -Wno-error=shorten-64-to-32 -Wno-shorten-64-to-32 -Wno-error=sync-alignment"
      ;;
  esac
else
  EXTRA_CXXFLAGS="${EXTRA_CXXFLAGS} -Wno-error=restrict"
fi

export EXTRA_CXXFLAGS
export EXTRA_CFLAGS
export EXTRA_LDFLAGS

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

validate_x86_64_gnu_abi() {
  local native_path="$1"
  local dynamic_dump
  local symbol_dump
  local glibc_versions
  local max_glibc_version
  local glibcxx_versions
  local max_glibcxx_version

  if ! hash objdump 2>/dev/null; then
    echo "objdump is required to validate GNU C++ ABI details in ${native_path}"
    exit 1
  fi

  dynamic_dump=$(objdump -p "${native_path}" 2>/dev/null || true)
  symbol_dump=$(objdump -T "${native_path}" 2>/dev/null || true)

  if ! printf '%s\n' "${dynamic_dump}" | grep -Eq 'NEEDED[[:space:]]+libstdc\+\+\.so\.6'; then
    echo "Expected ${native_path} to depend on libstdc++.so.6"
    exit 1
  fi

  if ! printf '%s\n' "${dynamic_dump}" | grep -Eq 'NEEDED[[:space:]]+libgcc_s\.so\.1'; then
    echo "Expected ${native_path} to depend on libgcc_s.so.1"
    exit 1
  fi

  if printf '%s\n' "${dynamic_dump}" | grep -Eq 'NEEDED[[:space:]]+(libsnappy|libz|libbz2|liblz4|libzstd|libjemalloc)\.so'; then
    echo "Unexpected dynamic compression or allocator dependency in ${native_path}"
    exit 1
  fi

  if ! printf '%s\n' "${symbol_dump}" | grep -Eq 'GLIBCXX_|CXXABI_'; then
    echo "Expected ${native_path} to reference GNU C++ ABI symbols"
    exit 1
  fi

  if printf '%s\n' "${symbol_dump}" | grep -Eq 'std::__1|St3__1'; then
    echo "Unexpected libc++ symbol namespace in ${native_path}"
    exit 1
  fi

  glibcxx_versions=$(printf '%s\n' "${symbol_dump}" | grep -oE 'GLIBCXX_[0-9.]+' | sort -Vu || true)
  if [ -z "${glibcxx_versions}" ]; then
    echo "Could not determine libstdc++ symbol requirements for ${native_path}"
    exit 1
  fi

  max_glibcxx_version=$(printf '%s\n' "${glibcxx_versions}" | sed 's/^GLIBCXX_//' | sort -V | tail -n1)
  if ! version_le "${max_glibcxx_version}" "${ROCKSDB_X86_64_GNU_GLIBCXX_MAX_VERSION}"; then
    echo "libstdc++ floor regression in ${native_path}: found GLIBCXX_${max_glibcxx_version}, expected <= GLIBCXX_${ROCKSDB_X86_64_GNU_GLIBCXX_MAX_VERSION}"
    exit 1
  fi

  glibc_versions=$(printf '%s\n' "${symbol_dump}" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu || true)
  if [ -z "${glibc_versions}" ]; then
    echo "Could not determine glibc symbol requirements for ${native_path}"
    exit 1
  fi

  max_glibc_version=$(printf '%s\n' "${glibc_versions}" | sed 's/^GLIBC_//' | sort -V | tail -n1)
  if ! version_le "${max_glibc_version}" "${ROCKSDB_X86_64_GNU_GLIBC_MAX_VERSION}"; then
    echo "glibc floor regression in ${native_path}: found GLIBC_${max_glibc_version}, expected <= GLIBC_${ROCKSDB_X86_64_GNU_GLIBC_MAX_VERSION}"
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

# DEBUG_LEVEL must be passed on the make command line, not just the environment:
# the Makefile forces DEBUG_LEVEL=0 for rocksdbjavastatic goals unless the value
# is 2, and that makefile assignment overrides an environment value but not a
# command-line one. Default to 0 so release builds are unaffected when unset.
DEBUG_LEVEL="${DEBUG_LEVEL:-0}"

# Use scl devtoolset if available
if hash scl 2>/dev/null; then
  DEVTOOLSET=$(scl --list | tr ' ' '\n' | grep -E '^devtoolset-[0-9]+$' | sort -V | tail -1)
  if [ -n "${DEVTOOLSET}" ]; then
    echo "Using ${DEVTOOLSET}"
    scl enable "${DEVTOOLSET}" 'make clean-not-downloaded'
    scl enable "${DEVTOOLSET}" "make -j${J} DEBUG_LEVEL=${DEBUG_LEVEL} rocksdbjavastatic"
  else
    echo "Could not find devtoolset, falling back to system toolchain"
    make clean-not-downloaded
    make -j"${J}" DEBUG_LEVEL="${DEBUG_LEVEL}" rocksdbjavastatic
  fi
else
  make clean-not-downloaded
  make -j"${J}" DEBUG_LEVEL="${DEBUG_LEVEL}" rocksdbjavastatic
fi

shopt -s nullglob
native_artifacts=(java/target/librocksdbjni-linux*.so)

if [ "${#native_artifacts[@]}" -eq 0 ]; then
  echo "No Linux JNI native artifacts were produced"
  exit 1
fi

for native_artifact in "${native_artifacts[@]}"; do
  validate_native_artifact "${native_artifact}"
  validate_no_sanitizer_refs "${native_artifact}"
  if [ "$(basename "${native_artifact}")" = "librocksdbjni-linux64.so" ] && [ "${ROCKSDB_CROSS_TRIPLE:-}" = "x86_64-linux-gnu" -o "${ROCKSDB_VALIDATE_X86_64_GNU_ABI:-0}" = "1" ]; then
    validate_x86_64_gnu_abi "${native_artifact}"
  fi
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
