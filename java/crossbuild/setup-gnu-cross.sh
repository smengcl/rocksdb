#!/usr/bin/env bash
# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.

set -euo pipefail

if [ -z "${ROCKSDB_CROSS_TRIPLE:-}" ]; then
  echo "ROCKSDB_CROSS_TRIPLE must be set"
  exit 1
fi

ROCKSDB_GNU_CROSS_CACHE="${ROCKSDB_GNU_CROSS_CACHE:-/rocksdb-gnu-cross}"
ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC="${ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC:-1.26.0}"
ROCKSDB_GNU_CROSS_CTNG_VERSION_MUSL="${ROCKSDB_GNU_CROSS_CTNG_VERSION_MUSL:-1.26.0}"
ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN:-2.38}"
ROCKSDB_GNU_CROSS_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION:-11.4.0}"
ROCKSDB_GNU_CROSS_GLIBC_VERSION="${ROCKSDB_GNU_CROSS_GLIBC_VERSION:-2.17}"
ROCKSDB_GNU_CROSS_GLIBC_VERSION_PPC64LE="${ROCKSDB_GNU_CROSS_GLIBC_VERSION_PPC64LE:-2.19}"
ROCKSDB_GNU_CROSS_GLIBC_VERSION_RISCV64="${ROCKSDB_GNU_CROSS_GLIBC_VERSION_RISCV64:-2.30}"
ROCKSDB_GNU_CROSS_MUSL_VERSION="${ROCKSDB_GNU_CROSS_MUSL_VERSION:-1.2.4}"
ROCKSDB_GNU_CROSS_LAYOUT_VERSION="${ROCKSDB_GNU_CROSS_LAYOUT_VERSION:-9}"
ROCKSDB_GNU_CROSS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROCKSDB_GNU_CROSS_TOOLCHAINS_DIR="${ROCKSDB_GNU_CROSS_CACHE}/toolchains"
ROCKSDB_GNU_CROSS_SOURCES_DIR="${ROCKSDB_GNU_CROSS_CACHE}/sources"
ROCKSDB_GNU_CROSS_WORK_DIR="${ROCKSDB_GNU_CROSS_WORK_DIR:-/rocksdb-local-build/w}"
ROCKSDB_GNU_CROSS_BUILD_DIR="${ROCKSDB_GNU_CROSS_BUILD_DIR:-/rocksdb-local-build/b}"
ROCKSDB_GNU_CROSS_LOCAL_TOOLCHAINS_DIR="${ROCKSDB_GNU_CROSS_LOCAL_TOOLCHAINS_DIR:-/rocksdb-local-build/t}"
ROCKSDB_GNU_CROSS_TMP_DIR="${ROCKSDB_GNU_CROSS_TMP_DIR:-/rocksdb-local-build/tmp}"

mkdir -p \
  "${ROCKSDB_GNU_CROSS_TOOLCHAINS_DIR}" \
  "${ROCKSDB_GNU_CROSS_SOURCES_DIR}" \
  "${ROCKSDB_GNU_CROSS_BUILD_DIR}" \
  "${ROCKSDB_GNU_CROSS_LOCAL_TOOLCHAINS_DIR}" \
  "${ROCKSDB_GNU_CROSS_TMP_DIR}"

ROCKSDB_GNU_COMMON_PACKAGES=(
  autoconf
  automake
  binutils
  bison
  build-essential
  ca-certificates
  chrpath
  cmake
  curl
  file
  flex
  gawk
  git
  gperf
  help2man
  libarchive-tools
  libncurses-dev
  libtool
  libtool-bin
  make
  patch
  patchelf
  pkg-config
  python3
  rsync
  texinfo
  unzip
  wget
  xz-utils
)

rocksdb_install_apt_packages() {
  if ! hash apt-get 2>/dev/null; then
    echo "GNU cross setup currently requires apt-get"
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "$@"
}

rocksdb_append_unique_flags() {
  local current="$1"
  shift
  local flag

  for flag in "$@"; do
    case " ${current} " in
      *" ${flag} "*)
        ;;
      *)
        current="${current} ${flag}"
        ;;
    esac
  done

  printf '%s\n' "${current# }"
}

rocksdb_set_kconfig_value() {
  local config_path="$1"
  local symbol="$2"
  local value="$3"
  local escaped_value

  escaped_value="$(printf '%s' "${value}" | sed 's/[\/&]/\\&/g')"
  if grep -Eq "^${symbol}=" "${config_path}"; then
    sed -i "s|^${symbol}=.*|${symbol}=\"${escaped_value}\"|" "${config_path}"
  else
    printf '%s="%s"\n' "${symbol}" "${value}" >> "${config_path}"
  fi
}

rocksdb_set_kconfig_int() {
  local config_path="$1"
  local symbol="$2"
  local value="$3"

  if grep -Eq "^${symbol}=" "${config_path}"; then
    sed -i "s|^${symbol}=.*|${symbol}=${value}|" "${config_path}"
  else
    printf '%s=%s\n' "${symbol}" "${value}" >> "${config_path}"
  fi
}

rocksdb_set_kconfig_bool() {
  local config_path="$1"
  local symbol="$2"
  local enabled="$3"

  if [ "${enabled}" = "y" ]; then
    if grep -Eq "^${symbol}=y$" "${config_path}"; then
      return 0
    fi
    sed -i \
      -e "/^${symbol}=y$/d" \
      -e "/^# ${symbol} is not set$/d" \
      "${config_path}"
    printf '%s=y\n' "${symbol}" >> "${config_path}"
  else
    if grep -Eq "^# ${symbol} is not set$" "${config_path}"; then
      return 0
    fi
    sed -i \
      -e "/^${symbol}=y$/d" \
      -e "/^# ${symbol} is not set$/d" \
      "${config_path}"
    printf '# %s is not set\n' "${symbol}" >> "${config_path}"
  fi
}

rocksdb_set_ctng_version_choice() {
  local config_path="$1"
  local prefix="$2"
  local version="$3"
  local ctng_version="$4"
  local symbol
  local choice_pattern

  case "${ctng_version}:${prefix}:${version}" in
    1.24.0:CT_BINUTILS:2.30)
      symbol=CT_BINUTILS_V_2_30
      ;;
    1.26.0:CT_BINUTILS:2.38)
      symbol=CT_BINUTILS_V_2_38
      ;;
    1.24.0:CT_GCC:4.8.5)
      symbol=CT_GCC_V_4_8
      ;;
    1.24.0:CT_GCC:6.5.0)
      symbol=CT_GCC_V_6
      ;;
    1.24.0:CT_GCC:8.2.0)
      symbol=CT_GCC_V_8
      ;;
    1.26.0:CT_GCC:6.5.0)
      symbol=CT_GCC_V_6_5_0
      ;;
    1.26.0:CT_GCC:8.2.0)
      symbol=CT_GCC_V_8_2_0
      ;;
    1.26.0:CT_GCC:11.4.0)
      symbol=CT_GCC_V_11
      ;;
    1.24.0:CT_GLIBC:2.12.2)
      symbol=CT_GLIBC_V_2_12_2
      ;;
    1.24.0:CT_GLIBC:2.16.0)
      symbol=CT_GLIBC_V_2_16_0
      ;;
    1.24.0:CT_GLIBC:2.17)
      symbol=CT_GLIBC_V_2_17
      ;;
    1.24.0:CT_GLIBC:2.29)
      symbol=CT_GLIBC_V_2_29
      ;;
    1.26.0:CT_GLIBC:2.17)
      symbol=CT_GLIBC_V_2_17
      ;;
    1.26.0:CT_GLIBC:2.19)
      symbol=CT_GLIBC_V_2_19
      ;;
    1.26.0:CT_GLIBC:2.29)
      symbol=CT_GLIBC_V_2_29
      ;;
    1.26.0:CT_GLIBC:2.30)
      symbol=CT_GLIBC_V_2_30
      ;;
    1.26.0:CT_MUSL:1.2.4)
      symbol=CT_MUSL_V_1_2_4
      ;;
    *)
      echo "Unsupported crosstool-NG version override ${prefix}=${version} for ct-ng ${ctng_version}"
      exit 1
      ;;
  esac

  choice_pattern="^${prefix}_V_"
  sed -i \
    -e "/${choice_pattern}/d" \
    -e "/^# ${prefix}_V_.* is not set$/d" \
    "${config_path}"
  rocksdb_set_kconfig_bool "${config_path}" "${symbol}" y
}

rocksdb_map_cross_target() {
GNU_APT_PACKAGES=()
GNU_TOOL_PREFIX=
GNU_TOOLCHAIN_KIND=
GNU_USE_OLD_HOST_COMPILER=n
GNU_HOST_CC=
GNU_HOST_CXX=
GNU_HOST_PATH_PREFIX=
GNU_CTNG_SAMPLE=
GNU_CTNG_BIN=
GNU_CTNG_VERSION=
GNU_CTNG_BINUTILS_VERSION=
GNU_CTNG_GCC_VERSION=
GNU_CTNG_GLIBC_VERSION=
GNU_CTNG_MUSL_VERSION=
GNU_CTNG_ROOT=
GNU_CTNG_URL=

  case "${ROCKSDB_CROSS_TRIPLE}" in
    x86-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=x86
      CROSS_TARGET_ARCHITECTURE=x86
      CROSS_MACHINE=x86
      CROSS_ARCH=32
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_CTNG_SAMPLE=i686-centos7-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_GLIBC_VERSION="${ROCKSDB_GNU_CROSS_GLIBC_VERSION}"
      ;;
    x86-linux-musl)
      CROSS_SYSTEM_PROCESSOR=x86
      CROSS_TARGET_ARCHITECTURE=x86
      CROSS_MACHINE=x86
      CROSS_ARCH=32
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=i686-nptl-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_MUSL}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_MUSL_VERSION="${ROCKSDB_GNU_CROSS_MUSL_VERSION}"
      ;;
    x86_64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=x86_64
      CROSS_TARGET_ARCHITECTURE=x86_64
      CROSS_MACHINE=x86_64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_CTNG_SAMPLE=x86_64-centos7-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_GLIBC_VERSION="${ROCKSDB_GNU_CROSS_GLIBC_VERSION}"
      ;;
    x86_64-linux-musl)
      CROSS_SYSTEM_PROCESSOR=x86_64
      CROSS_TARGET_ARCHITECTURE=x86_64
      CROSS_MACHINE=x86_64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=x86_64-multilib-linux-musl
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_MUSL}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_MUSL_VERSION="${ROCKSDB_GNU_CROSS_MUSL_VERSION}"
      ;;
    powerpc64le-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=ppc64le
      CROSS_TARGET_ARCHITECTURE=ppc64le
      CROSS_MACHINE=ppc64le
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_CTNG_SAMPLE=powerpc64le-unknown-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_GLIBC_VERSION="${ROCKSDB_GNU_CROSS_GLIBC_VERSION_PPC64LE}"
      ;;
    powerpc64le-linux-musl)
      CROSS_SYSTEM_PROCESSOR=ppc64le
      CROSS_TARGET_ARCHITECTURE=ppc64le
      CROSS_MACHINE=ppc64le
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=powerpc64le-unknown-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_MUSL}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_MUSL_VERSION="${ROCKSDB_GNU_CROSS_MUSL_VERSION}"
      ;;
    s390x-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=s390x
      CROSS_TARGET_ARCHITECTURE=s390x
      CROSS_MACHINE=s390x
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_CTNG_SAMPLE=s390x-ibm-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_GLIBC_VERSION="${ROCKSDB_GNU_CROSS_GLIBC_VERSION}"
      ;;
    s390x-linux-musl)
      CROSS_SYSTEM_PROCESSOR=s390x
      CROSS_TARGET_ARCHITECTURE=s390x
      CROSS_MACHINE=s390x
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=s390x-ibm-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_MUSL}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_MUSL_VERSION="${ROCKSDB_GNU_CROSS_MUSL_VERSION}"
      ;;
    riscv64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=riscv64
      CROSS_TARGET_ARCHITECTURE=riscv64
      CROSS_MACHINE=riscv64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_CTNG_SAMPLE=riscv64-unknown-linux-gnu
      GNU_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION_GLIBC}"
      GNU_CTNG_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION_MODERN}"
      GNU_CTNG_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION}"
      GNU_CTNG_GLIBC_VERSION="${ROCKSDB_GNU_CROSS_GLIBC_VERSION_RISCV64}"
      ;;
    *)
      echo "Unsupported ROCKSDB_CROSS_TRIPLE: ${ROCKSDB_CROSS_TRIPLE}"
      exit 1
      ;;
  esac

  if [ "${GNU_USE_OLD_HOST_COMPILER}" = "y" ]; then
    GNU_HOST_CC=gcc-10
    GNU_HOST_CXX=g++-10
  fi
}

rocksdb_write_ctng_overrides() {
  local config_path="$1"
  local toolchain_root="$2"

  rocksdb_set_kconfig_bool "${config_path}" CT_ALLOW_BUILD_AS_ROOT y
  rocksdb_set_kconfig_bool "${config_path}" CT_ALLOW_BUILD_AS_ROOT_SURE y
  rocksdb_set_kconfig_bool "${config_path}" CT_EXPERIMENTAL y
  rocksdb_set_kconfig_bool "${config_path}" CT_PATCH_BUNDLED y
  rocksdb_set_kconfig_bool "${config_path}" CT_PATCH_LOCAL n
  rocksdb_set_kconfig_bool "${config_path}" CT_PATCH_BUNDLED_LOCAL n
  rocksdb_set_kconfig_bool "${config_path}" CT_PATCH_LOCAL_BUNDLED n
  rocksdb_set_kconfig_bool "${config_path}" CT_PATCH_NONE n
  rocksdb_set_ctng_version_choice "${config_path}" CT_BINUTILS "${GNU_CTNG_BINUTILS_VERSION}" "${GNU_CTNG_VERSION}"
  rocksdb_set_ctng_version_choice "${config_path}" CT_GCC "${GNU_CTNG_GCC_VERSION}" "${GNU_CTNG_VERSION}"
  rocksdb_set_kconfig_value "${config_path}" CT_LOCAL_TARBALLS_DIR "${ROCKSDB_GNU_CROSS_SOURCES_DIR}"
  rocksdb_set_kconfig_value "${config_path}" CT_PREFIX_DIR "${toolchain_root}"
  rocksdb_set_kconfig_bool "${config_path}" CT_SAVE_TARBALLS y
  if [ "${GNU_TOOLCHAIN_KIND}" = "glibc" ]; then
    rocksdb_set_ctng_version_choice "${config_path}" CT_GLIBC "${GNU_CTNG_GLIBC_VERSION}" "${GNU_CTNG_VERSION}"
    rocksdb_set_kconfig_bool "${config_path}" CT_LIBC_GLIBC y
    rocksdb_set_kconfig_bool "${config_path}" CT_LIBC_MUSL n
  else
    rocksdb_set_ctng_version_choice "${config_path}" CT_MUSL "${GNU_CTNG_MUSL_VERSION}" "${GNU_CTNG_VERSION}"
    rocksdb_set_kconfig_bool "${config_path}" CT_LIBC_MUSL y
    rocksdb_set_kconfig_bool "${config_path}" CT_LIBC_GLIBC n
  fi
  rocksdb_set_kconfig_bool "${config_path}" CT_DEBUG_DUMA n
  rocksdb_set_kconfig_bool "${config_path}" CT_DEBUG_GDB n
  rocksdb_set_kconfig_bool "${config_path}" CT_DEBUG_LTRACE n
  rocksdb_set_kconfig_bool "${config_path}" CT_DEBUG_STRACE n
  rocksdb_set_kconfig_bool "${config_path}" CT_GDB_GDBSERVER n
  rocksdb_set_kconfig_bool "${config_path}" CT_GDB_NATIVE n
  rocksdb_set_kconfig_bool "${config_path}" CT_GDB_NATIVE_STATIC n
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_LINKER_LD y
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_LINKER_GOLD n
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_LINKER_LD_GOLD n
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_LINKER_GOLD_LD n
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_GOLD_THREADS n
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_LD_WRAPPER n
  rocksdb_set_kconfig_bool "${config_path}" CT_BINUTILS_PLUGINS n
  rocksdb_set_kconfig_bool "${config_path}" CT_CC_GCC_ENABLE_PLUGINS n
  rocksdb_set_kconfig_bool "${config_path}" CT_CC_GCC_USE_LTO n
  if [ "${GNU_USE_OLD_HOST_COMPILER}" = "y" ]; then
    # Old-floor glibc toolchains with GCC 4.8.5 are memory-heavy on arm64
    # runners; cap ct-ng parallelism to avoid OOM kills.
    rocksdb_set_kconfig_int "${config_path}" CT_PARALLEL_JOBS 2
    rocksdb_set_kconfig_value "${config_path}" CT_LOAD ""
  fi

}

rocksdb_select_ctng_runtime() {
  GNU_CTNG_ROOT="${ROCKSDB_GNU_CROSS_CACHE}/ctng/${GNU_CTNG_VERSION}"
  GNU_CTNG_URL="https://github.com/crosstool-ng/crosstool-ng/archive/refs/tags/crosstool-ng-${GNU_CTNG_VERSION}.tar.gz"
}

rocksdb_ctng_command() {
  if [ -n "${GNU_HOST_PATH_PREFIX}" ]; then
    env PATH="${GNU_HOST_PATH_PREFIX}:${PATH}" "$@"
  else
    "$@"
  fi
}

rocksdb_prepare_old_host_compiler_path() {
  local host_tools_dir

  if [ -z "${GNU_HOST_CC}" ] || [ -z "${GNU_HOST_CXX}" ]; then
    return 0
  fi

  host_tools_dir="${ROCKSDB_GNU_CROSS_TMP_DIR}/host-tools"
  mkdir -p "${host_tools_dir}"
  ln -sfn "$(command -v "${GNU_HOST_CC}")" "${host_tools_dir}/gcc"
  ln -sfn "$(command -v "${GNU_HOST_CXX}")" "${host_tools_dir}/g++"
  ln -sfn "$(command -v "${GNU_HOST_CC}")" "${host_tools_dir}/cc"
  ln -sfn "$(command -v "${GNU_HOST_CXX}")" "${host_tools_dir}/c++"
  GNU_HOST_PATH_PREFIX="${host_tools_dir}"
}

rocksdb_validate_ctng_toolchain() {
  local gcc_path="$1"
  local required
  local resolved

  for required in crt1.o crti.o crtn.o crtbeginS.o crtendS.o libgcc.a; do
    resolved="$("${gcc_path}" -print-file-name="${required}")"
    if [ -z "${resolved}" ] || [ "${resolved}" = "${required}" ] || [ ! -e "${resolved}" ]; then
      echo "GNU cross toolchain is missing ${required} (${resolved})"
      return 1
    fi
  done

  if [ "${GNU_TOOLCHAIN_KIND}" = "musl" ]; then
    for required in libstdc++.a; do
      resolved="$("${gcc_path}" -print-file-name="${required}")"
      if [ -z "${resolved}" ] || [ "${resolved}" = "${required}" ] || [ ! -e "${resolved}" ]; then
        echo "GNU musl cross toolchain is missing ${required} (${resolved})"
        return 1
      fi
    done
  fi

  return 0
}

rocksdb_find_toolchain_target() {
  local toolchain_root="$1"
  local candidate

  for candidate in "${toolchain_root}"/bin/*-gcc; do
    [ -e "${candidate}" ] || continue
    basename "${candidate}" -gcc
    return 0
  done

  return 1
}

rocksdb_sync_dir() {
  local src="$1"
  local dst="$2"

  mkdir -p "${dst}"
  chmod -R u+rwX "${dst}" 2>/dev/null || true
  rsync -a --delete --chmod=Du=rwx,Dgo=rx,Fu=rwX,Fgo=rX "${src}/" "${dst}/"
}

rocksdb_fetch_with_fallbacks() {
  local output_path="$1"
  shift
  local url

  for url in "$@"; do
    if curl -fsSL "${url}" -o "${output_path}.tmp"; then
      mv -f "${output_path}.tmp" "${output_path}"
      return 0
    fi
  done

  rm -f "${output_path}.tmp"
  echo "Failed to fetch $(basename "${output_path}") from all fallback URLs"
  return 1
}

rocksdb_prefetch_legacy_ctng_tarballs() {
  if [ "${GNU_CTNG_VERSION}" != "1.24.0" ]; then
    return 0
  fi

  mkdir -p "${ROCKSDB_GNU_CROSS_SOURCES_DIR}"

  if [ ! -f "${ROCKSDB_GNU_CROSS_SOURCES_DIR}/isl-0.12.2.tar.bz2" ]; then
    rocksdb_fetch_with_fallbacks \
      "${ROCKSDB_GNU_CROSS_SOURCES_DIR}/isl-0.12.2.tar.bz2" \
      "https://libisl.sourceforge.io/isl-0.12.2.tar.bz2" \
      "https://gcc.gnu.org/pub/gcc/infrastructure/isl-0.12.2.tar.bz2"
  fi

  if [ ! -f "${ROCKSDB_GNU_CROSS_SOURCES_DIR}/isl-0.20.tar.xz" ]; then
    rocksdb_fetch_with_fallbacks \
      "${ROCKSDB_GNU_CROSS_SOURCES_DIR}/isl-0.20.tar.xz" \
      "https://libisl.sourceforge.io/isl-0.20.tar.xz" \
      "https://gcc.gnu.org/pub/gcc/infrastructure/isl-0.20.tar.xz"
  fi
}

rocksdb_make_toolchain_id() {
  local cache_key
  local cache_hash
  local short_target

  cache_key="${GNU_CTNG_VERSION}|${GNU_CTNG_BINUTILS_VERSION}|${GNU_CTNG_GCC_VERSION}|${GNU_CTNG_GLIBC_VERSION}|${GNU_CTNG_MUSL_VERSION}|${ROCKSDB_GNU_CROSS_LAYOUT_VERSION}|${GNU_TOOLCHAIN_KIND}|${ROCKSDB_CROSS_TRIPLE}"
  cache_hash="$(printf '%s' "${cache_key}" | cksum | awk '{print $1}')"
  short_target="$(printf '%s' "${ROCKSDB_CROSS_TRIPLE}" | sed 's/[^A-Za-z0-9]/-/g')"
  printf 'tc-%s-%s\n' "${short_target}" "${cache_hash}"
}

rocksdb_patch_ctng_install() {
  local functions_path="${GNU_CTNG_ROOT}/share/crosstool-ng/scripts/functions"
  local glibc_build_path="${GNU_CTNG_ROOT}/share/crosstool-ng/scripts/build/libc/glibc.sh"
  local isl20_chksum_path="${GNU_CTNG_ROOT}/share/crosstool-ng/packages/isl/0.20/chksum"

  if [ -f "${functions_path}" ] && ! grep -Fq 'CT_DoExecLog FILE ${CT_TAR:-tar} x -v -f - -C "${dir}" ${components}' "${functions_path}"; then
    sed -i \
      's|CT_DoExecLog FILE tar x -v -f - -C "${dir}" ${components}|CT_DoExecLog FILE ${CT_TAR:-tar} x -v -f - -C "${dir}" ${components}|' \
      "${functions_path}"
  fi

  if [ -f "${isl20_chksum_path}" ] && grep -Fq 'isl-0.19' "${isl20_chksum_path}"; then
    cat > "${isl20_chksum_path}" <<'EOF'
md5 isl-0.20.tar.xz 2ee25141b7d1688afb63e5bf3ac12999
sha1 isl-0.20.tar.xz 1cb65006e8b047a52534e9a237748e56cfbd2754
sha256 isl-0.20.tar.xz a5596a9fb8a5b365cb612e4b9628735d6e67e9178fae134a816ae195017e77aa
sha512 isl-0.20.tar.xz 394bccd22d8e63cb052a60ad8b1a75f4ec43916a9482c66f5167b534b538161179c47919815983b7fbc20dfaa1a590e88b251850aa092bbffc2891635bf30dc4
md5 isl-0.20.tar.bz2 cb396f31b24aeeac49840b519741b0e1
sha1 isl-0.20.tar.bz2 b1d96b7b44c72f86c98d4fbd4caaa7796b27681e
sha256 isl-0.20.tar.bz2 b587e083eb65a8b394e833dea1744f21af3f0e413a448c17536b5549ae42a4c2
sha512 isl-0.20.tar.bz2 afe2e159b74646a26449268637403d271f9e3f6410d8cc1c9cffca41370c4357b165dea844db0c2a654591f954e54710dda650c8088abd4711406aa6302da950
md5 isl-0.20.tar.gz f43f6ef445ec5c7e9ec5db42a41f7f28
sha1 isl-0.20.tar.gz d0d43b6344e048f98666eb2e5181a91eeb360f8c
sha256 isl-0.20.tar.gz ddc2d7fbd75bd3e3c5b3ea6ee3ef0f805ef9b6b2e5d8cf4c34239a6ea21328a4
sha512 isl-0.20.tar.gz b73a02285bc0fa412f470f4ac29b07196c4be99248f8257296ed25f0cb73a6782e89eb2461fbf83c6ae2443a88edf52d7214d173b99e5650eb6b0774f8d53658
EOF
  fi

  if [ -f "${glibc_build_path}" ] && \
     grep -Fq 'install-bootstrap-headers=yes' "${glibc_build_path}" && \
     ! grep -Fq 'cross-compiling=yes' "${glibc_build_path}"; then
    python3 - "${glibc_build_path}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """                         install-bootstrap-headers=yes              \\\n                         "${extra_make_args[@]}"                    \\\n"""
new = """                         install-bootstrap-headers=yes              \\\n                         cross-compiling=yes                     \\\n                         "${extra_make_args[@]}"                    \\\n"""
if old in text and "cross-compiling=yes" not in text:
    path.write_text(text.replace(old, new, 1))
PY
  fi

  if [ -f "${glibc_build_path}" ] && \
     grep -Fq 'cross-compiling=yes' "${glibc_build_path}" && \
     ! grep -Fq 'Serialise old glibc sunrpc header install' "${glibc_build_path}"; then
    python3 - "${glibc_build_path}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
pattern = re.compile(
    r'''(?P<indent>\s*)# use the 'install-headers' makefile target to install the\n'''
    r'''(?P=indent)# headers\n'''
    r'''(?P=indent)CT_DoExecLog ALL make \${CT_JOBSFLAGS}\s+\\\\\n'''
    r'''(?P=indent)\s*install_root=\${multi_root}\s+\\\\\n'''
    r'''(?P=indent)\s*install-bootstrap-headers=yes\s+\\\\\n'''
    r'''(?P=indent)\s*cross-compiling=yes\s+\\\\\n'''
    r'''(?P=indent)\s*"\${extra_make_args\[@\]}"\s+\\\\\n'''
    r'''(?P=indent)\s*install-headers\n''',
    re.MULTILINE,
)
replacement = """        # use the 'install-headers' makefile target to install the\n        # headers\n        if [ -d \"${src_dir}/sunrpc\" ]; then\n            # Serialise old glibc sunrpc header install to avoid rpcgen races.\n            CT_DoExecLog ALL make -j1                                \\\n                             install_root=${multi_root}             \\\n                             install-bootstrap-headers=yes          \\\n                             cross-compiling=yes                    \\\n                             \"${extra_make_args[@]}\"                \\\n                             install-headers\n        else\n            CT_DoExecLog ALL make ${CT_JOBSFLAGS}                   \\\n                             install_root=${multi_root}             \\\n                             install-bootstrap-headers=yes          \\\n                             cross-compiling=yes                    \\\n                             \"${extra_make_args[@]}\"                \\\n                             install-headers\n        fi\n"""
text2, count = pattern.subn(replacement, text, count=1)
if count and "Serialise old glibc sunrpc header install" not in text:
    path.write_text(text2)
PY
  fi

  if [ -f "${glibc_build_path}" ] && \
     grep -Fq 'install-bootstrap-headers=yes' "${glibc_build_path}" && \
     ! grep -Fq 'Pre-seed old glibc sunrpc headers' "${glibc_build_path}"; then
    python3 - "${glibc_build_path}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """        CT_DoLog EXTRA "Installing C library headers"\n        CT_DoExecLog ALL touch "${multi_root}/.libc_headers_installed"\n\n        # use the 'install-headers' makefile target to install the\n"""
new = """        CT_DoLog EXTRA "Installing C library headers"\n        CT_DoExecLog ALL touch "${multi_root}/.libc_headers_installed"\n\n        # Pre-seed old glibc sunrpc headers so rpcgen helper sources can\n        # include <rpc/types.h> during install-headers on modern hosts.\n        CT_DoExecLog ALL mkdir -p "${multi_root}/usr/include/rpc" "${multi_root}/usr/include/sunrpc/rpc"\n        CT_DoExecLog ALL cp -f "${src_dir}/sunrpc/rpc/types.h" "${multi_root}/usr/include/rpc/types.h"\n        CT_DoExecLog ALL cp -f "${src_dir}/sunrpc/rpc/types.h" "${multi_root}/usr/include/sunrpc/rpc/types.h"\n        CT_DoExecLog ALL mkdir -p rpc sunrpc/rpc\n        CT_DoExecLog ALL cp -f "${src_dir}/sunrpc/rpc/types.h" rpc/types.h\n        CT_DoExecLog ALL cp -f "${src_dir}/sunrpc/rpc/types.h" sunrpc/rpc/types.h\n\n        # use the 'install-headers' makefile target to install the\n"""
if old in text and "Pre-seed old glibc sunrpc headers" not in text:
    path.write_text(text.replace(old, new, 1))
PY
  fi

  if [ -f "${glibc_build_path}" ]; then
    python3 - "${glibc_build_path}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = """    if [ -d "${src_dir}/sunrpc" ]; then\n        # Add sysroot include paths for old glibc sunrpc helpers.\n        build_cppflags="${build_cppflags} -I${multi_root}/usr/include -I${multi_root}/usr/include/sunrpc"\n    fi\n\n    extra_make_args+=( "BUILD_CFLAGS=${build_cflags}" )\n    extra_make_args+=( "BUILD_CPPFLAGS=${build_cppflags}" )\n"""
new = """    if [ -d "${src_dir}/sunrpc" ]; then\n        # Old glibc sunrpc host helpers include <rpc/types.h> from the source tree.\n        build_cppflags="${build_cppflags} -I${src_dir}/sunrpc"\n    fi\n\n    extra_make_args+=( "BUILD_CFLAGS=${build_cflags}" )\n    extra_make_args+=( "BUILD_CPPFLAGS=${build_cppflags}" )\n"""
if old in text:
    path.write_text(text.replace(old, new, 1))
elif 'build_cppflags="${build_cppflags} -I${src_dir}/sunrpc"' not in text:
    anchor = """    extra_make_args+=( "BUILD_CFLAGS=${build_cflags}" )\n    extra_make_args+=( "BUILD_CPPFLAGS=${build_cppflags}" )\n"""
    replacement = """    if [ -d "${src_dir}/sunrpc" ]; then\n        # Old glibc sunrpc host helpers include <rpc/types.h> from the source tree.\n        build_cppflags="${build_cppflags} -I${src_dir}/sunrpc"\n    fi\n\n    extra_make_args+=( "BUILD_CFLAGS=${build_cflags}" )\n    extra_make_args+=( "BUILD_CPPFLAGS=${build_cppflags}" )\n"""
    if anchor in text:
        path.write_text(text.replace(anchor, replacement, 1))
PY
  fi
}

rocksdb_ensure_ctng() {
  local ctng_bin="${GNU_CTNG_ROOT}/bin/ct-ng"
  local ctng_src_tar="${ROCKSDB_GNU_CROSS_SOURCES_DIR}/crosstool-ng-${GNU_CTNG_VERSION}.tar.gz"
  local ctng_src_dir
  local ctng_src_topdir
  local ctng_listing

  if [ -x "${ctng_bin}" ]; then
    rocksdb_patch_ctng_install
    GNU_CTNG_BIN="${ctng_bin}"
    return 0
  fi

  if [ ! -f "${ctng_src_tar}" ]; then
    curl -fsSL "${GNU_CTNG_URL}" -o "${ctng_src_tar}"
  fi

  ctng_listing="${ROCKSDB_GNU_CROSS_TMP_DIR}/crosstool-ng-${GNU_CTNG_VERSION}.listing"
  tar -tzf "${ctng_src_tar}" > "${ctng_listing}"
  ctng_src_topdir="$(sed -n '1{s,/.*,,;p;}' "${ctng_listing}")"
  rm -f "${ctng_listing}"
  test -n "${ctng_src_topdir}"
  ctng_src_dir="${ROCKSDB_GNU_CROSS_TMP_DIR}/${ctng_src_topdir}"
  rm -rf "${ctng_src_dir}"
  tar -C "${ROCKSDB_GNU_CROSS_TMP_DIR}" -xzf "${ctng_src_tar}"

  pushd "${ctng_src_dir}" >/dev/null
  rocksdb_ctng_command ./bootstrap
  rocksdb_ctng_command ./configure --prefix="${GNU_CTNG_ROOT}"
  rocksdb_ctng_command make -j"$(nproc)"
  rocksdb_ctng_command make install
  popd >/dev/null

  rocksdb_patch_ctng_install
  GNU_CTNG_BIN="${ctng_bin}"
}

rocksdb_ensure_ctng_toolchain() {
  local toolchain_id
  local cache_toolchain_root
  local local_toolchain_root
  local build_root
  local cache_ready_stamp
  local local_ready_stamp
  local ct_target
  local gcc_path

  toolchain_id="$(rocksdb_make_toolchain_id)"
  cache_toolchain_root="${ROCKSDB_GNU_CROSS_TOOLCHAINS_DIR}/${toolchain_id}"
  local_toolchain_root="${ROCKSDB_GNU_CROSS_LOCAL_TOOLCHAINS_DIR}/${toolchain_id}"
  build_root="${ROCKSDB_GNU_CROSS_BUILD_DIR}/${toolchain_id}"
  cache_ready_stamp="${cache_toolchain_root}/.ready"
  local_ready_stamp="${local_toolchain_root}/.ready"

  if [ -f "${cache_ready_stamp}" ]; then
    ct_target="$(rocksdb_find_toolchain_target "${cache_toolchain_root}" || true)"
    if [ -n "${ct_target}" ] && rocksdb_validate_ctng_toolchain "${cache_toolchain_root}/bin/${ct_target}-gcc"; then
      GNU_TOOL_PREFIX="${ct_target}"
      GNU_TOOLCHAIN_ROOT="${cache_toolchain_root}"
      return 0
    fi

    rm -rf "${cache_toolchain_root}"
  fi

  if [ -f "${local_ready_stamp}" ]; then
    local cached_target=

    cached_target="$(rocksdb_find_toolchain_target "${local_toolchain_root}" || true)"

    if [ -z "${cached_target}" ] || ! rocksdb_validate_ctng_toolchain "${local_toolchain_root}/bin/${cached_target}-gcc"; then
      rm -rf "${local_toolchain_root}" "${cache_toolchain_root}"
    fi
  fi

  if [ ! -f "${local_ready_stamp}" ]; then
    local ctng_bin

    rocksdb_ensure_ctng
    ctng_bin="${GNU_CTNG_BIN}"
    rm -rf "${build_root}" "${local_toolchain_root}"
    mkdir -p "${build_root}" "${local_toolchain_root}"

    pushd "${build_root}" >/dev/null
    rocksdb_ctng_command "${ctng_bin}" "${GNU_CTNG_SAMPLE}"
    rocksdb_write_ctng_overrides .config "${local_toolchain_root}"
    rocksdb_ctng_command "${ctng_bin}" olddefconfig
    rocksdb_ctng_command "${ctng_bin}" build
    ct_target=
    for gcc_path in "${local_toolchain_root}"/bin/*-gcc; do
      [ -e "${gcc_path}" ] || continue
      ct_target="$(basename "${gcc_path}" -gcc)"
      break
    done
    test -n "${ct_target}"
    test -x "${local_toolchain_root}/bin/${ct_target}-gcc"
    touch "${local_ready_stamp}"
    popd >/dev/null

    rm -rf "${cache_toolchain_root}"
    mkdir -p "${cache_toolchain_root}"
    rocksdb_sync_dir "${local_toolchain_root}" "${cache_toolchain_root}"
    touch "${cache_ready_stamp}"
  fi

  ct_target="$(rocksdb_find_toolchain_target "${cache_toolchain_root}" || true)"
  if [ -z "${ct_target}" ] || ! rocksdb_validate_ctng_toolchain "${cache_toolchain_root}/bin/${ct_target}-gcc"; then
    echo "GNU cross toolchain cache is invalid after synchronization"
    exit 1
  fi
  test -n "${ct_target}"
  GNU_TOOL_PREFIX="${ct_target}"
  GNU_TOOLCHAIN_ROOT="${cache_toolchain_root}"
}

rocksdb_export_cross_toolchain() {
  local toolchain_bin="$1"

  export CC="${toolchain_bin}/${GNU_TOOL_PREFIX}-gcc"
  export CXX="${toolchain_bin}/${GNU_TOOL_PREFIX}-g++"
  export AR="${toolchain_bin}/${GNU_TOOL_PREFIX}-ar"
  export AS="${toolchain_bin}/${GNU_TOOL_PREFIX}-as"
  export LD="${toolchain_bin}/${GNU_TOOL_PREFIX}-ld"
  export NM="${toolchain_bin}/${GNU_TOOL_PREFIX}-nm"
  export OBJDUMP="${toolchain_bin}/${GNU_TOOL_PREFIX}-objdump"
  export RANLIB="${toolchain_bin}/${GNU_TOOL_PREFIX}-ranlib"
  export READELF="${toolchain_bin}/${GNU_TOOL_PREFIX}-readelf"
  export STRIP="${toolchain_bin}/${GNU_TOOL_PREFIX}-strip"
  export CROSS_COMPILE="${toolchain_bin}/${GNU_TOOL_PREFIX}-"

  export TARGET_ARCHITECTURE="${CROSS_TARGET_ARCHITECTURE}"
  export MACHINE="${CROSS_MACHINE}"
  export ARCH="${CROSS_ARCH}"
  export ROCKSDB_CROSS_LIBC="${CROSS_JNI_LIBC:-gnu}"
  if [ -n "${CROSS_JNI_LIBC}" ]; then
    export JNI_LIBC="${CROSS_JNI_LIBC}"
  else
    unset JNI_LIBC
  fi

  export PLATFORM_CMAKE_FLAGS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=${CROSS_SYSTEM_PROCESSOR} -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX}"
}

rocksdb_setup_gnu_cross_toolchain() {
  local toolchain_bin

  rocksdb_map_cross_target
  rocksdb_select_ctng_runtime
  rocksdb_prefetch_legacy_ctng_tarballs

  if [ "${GNU_USE_OLD_HOST_COMPILER}" = "y" ]; then
    rocksdb_install_apt_packages "${ROCKSDB_GNU_COMMON_PACKAGES[@]}" gcc-10 g++-10
  else
    rocksdb_install_apt_packages "${ROCKSDB_GNU_COMMON_PACKAGES[@]}"
  fi
  if [ "${GNU_TOOLCHAIN_KIND}" = "musl" ] && hash bsdtar 2>/dev/null; then
    export CT_TAR=bsdtar
  fi
  rocksdb_prepare_old_host_compiler_path
  rocksdb_ensure_ctng_toolchain
  toolchain_bin="${GNU_TOOLCHAIN_ROOT}/bin"

  rocksdb_export_cross_toolchain "${toolchain_bin}"

  for tool in "${CC}" "${CXX}" "${AR}" "${AS}" "${LD}" "${NM}" "${OBJDUMP}" "${RANLIB}" "${READELF}" "${STRIP}"; do
    test -x "${tool}"
  done
}
