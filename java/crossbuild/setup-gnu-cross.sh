#!/usr/bin/env bash
# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.

set -euo pipefail

if [ -z "${ROCKSDB_CROSS_TRIPLE:-}" ]; then
  echo "ROCKSDB_CROSS_TRIPLE must be set"
  exit 1
fi

ROCKSDB_GNU_CROSS_CACHE="${ROCKSDB_GNU_CROSS_CACHE:-/rocksdb-gnu-cross}"
ROCKSDB_GNU_CROSS_CTNG_VERSION="${ROCKSDB_GNU_CROSS_CTNG_VERSION:-1.26.0}"
ROCKSDB_GNU_CROSS_BINUTILS_VERSION="${ROCKSDB_GNU_CROSS_BINUTILS_VERSION:-2.38}"
ROCKSDB_GNU_CROSS_GCC_VERSION="${ROCKSDB_GNU_CROSS_GCC_VERSION:-11.4.0}"
ROCKSDB_GNU_CROSS_MUSL_VERSION="${ROCKSDB_GNU_CROSS_MUSL_VERSION:-1.2.4}"
ROCKSDB_GNU_CROSS_LAYOUT_VERSION="${ROCKSDB_GNU_CROSS_LAYOUT_VERSION:-3}"
ROCKSDB_GNU_CROSS_CTNG_URL="${ROCKSDB_GNU_CROSS_CTNG_URL:-https://github.com/crosstool-ng/crosstool-ng/archive/refs/tags/crosstool-ng-${ROCKSDB_GNU_CROSS_CTNG_VERSION}.tar.gz}"

ROCKSDB_GNU_CROSS_CTNG_ROOT="${ROCKSDB_GNU_CROSS_CACHE}/ctng/${ROCKSDB_GNU_CROSS_CTNG_VERSION}"
ROCKSDB_GNU_CROSS_TOOLCHAINS_DIR="${ROCKSDB_GNU_CROSS_CACHE}/toolchains"
ROCKSDB_GNU_CROSS_SOURCES_DIR="${ROCKSDB_GNU_CROSS_CACHE}/sources"
ROCKSDB_GNU_CROSS_WORK_DIR="${ROCKSDB_GNU_CROSS_WORK_DIR:-/rocksdb-local-build/w}"
ROCKSDB_GNU_CROSS_BUILD_DIR="${ROCKSDB_GNU_CROSS_BUILD_DIR:-/rocksdb-local-build/b}"
ROCKSDB_GNU_CROSS_LOCAL_TOOLCHAINS_DIR="${ROCKSDB_GNU_CROSS_LOCAL_TOOLCHAINS_DIR:-/rocksdb-local-build/t}"
ROCKSDB_GNU_CROSS_TMP_DIR="${ROCKSDB_GNU_CROSS_TMP_DIR:-/rocksdb-local-build/tmp}"

mkdir -p \
  "${ROCKSDB_GNU_CROSS_CTNG_ROOT}" \
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
  local symbol

  case "${prefix}:${version}" in
    CT_BINUTILS:2.38)
      symbol=CT_BINUTILS_V_2_38
      ;;
    CT_GCC:11.4.0)
      symbol=CT_GCC_V_11
      ;;
    CT_MUSL:1.2.4)
      symbol=CT_MUSL_V_1_2_4
      ;;
    *)
      echo "Unsupported crosstool-NG version override ${prefix}=${version}"
      exit 1
      ;;
  esac

  rocksdb_set_kconfig_bool "${config_path}" "${symbol}" y
}

rocksdb_map_cross_target() {
GNU_APT_PACKAGES=()
GNU_TOOL_PREFIX=
GNU_TOOLCHAIN_KIND=
GNU_CTNG_SAMPLE=
GNU_CTNG_BIN=

  case "${ROCKSDB_CROSS_TRIPLE}" in
    x86-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=x86
      CROSS_TARGET_ARCHITECTURE=x86
      CROSS_MACHINE=x86
      CROSS_ARCH=32
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_TOOL_PREFIX=i686-linux-gnu
      GNU_APT_PACKAGES=(gcc-i686-linux-gnu g++-i686-linux-gnu binutils-i686-linux-gnu)
      ;;
    x86-linux-musl)
      CROSS_SYSTEM_PROCESSOR=x86
      CROSS_TARGET_ARCHITECTURE=x86
      CROSS_MACHINE=x86
      CROSS_ARCH=32
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=i686-nptl-linux-gnu
      ;;
    x86_64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=x86_64
      CROSS_TARGET_ARCHITECTURE=x86_64
      CROSS_MACHINE=x86_64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_TOOL_PREFIX=x86_64-linux-gnu
      GNU_APT_PACKAGES=(gcc-x86-64-linux-gnu g++-x86-64-linux-gnu binutils-x86-64-linux-gnu)
      ;;
    x86_64-linux-musl)
      CROSS_SYSTEM_PROCESSOR=x86_64
      CROSS_TARGET_ARCHITECTURE=x86_64
      CROSS_MACHINE=x86_64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=x86_64-multilib-linux-musl
      ;;
    powerpc64le-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=ppc64le
      CROSS_TARGET_ARCHITECTURE=ppc64le
      CROSS_MACHINE=ppc64le
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_TOOL_PREFIX=powerpc64le-linux-gnu
      GNU_APT_PACKAGES=(gcc-powerpc64le-linux-gnu g++-powerpc64le-linux-gnu binutils-powerpc64le-linux-gnu)
      ;;
    powerpc64le-linux-musl)
      CROSS_SYSTEM_PROCESSOR=ppc64le
      CROSS_TARGET_ARCHITECTURE=ppc64le
      CROSS_MACHINE=ppc64le
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=powerpc64le-unknown-linux-gnu
      ;;
    s390x-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=s390x
      CROSS_TARGET_ARCHITECTURE=s390x
      CROSS_MACHINE=s390x
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_TOOL_PREFIX=s390x-linux-gnu
      GNU_APT_PACKAGES=(gcc-s390x-linux-gnu g++-s390x-linux-gnu binutils-s390x-linux-gnu)
      ;;
    s390x-linux-musl)
      CROSS_SYSTEM_PROCESSOR=s390x
      CROSS_TARGET_ARCHITECTURE=s390x
      CROSS_MACHINE=s390x
      CROSS_ARCH=64
      CROSS_JNI_LIBC=musl
      GNU_TOOLCHAIN_KIND=musl
      GNU_CTNG_SAMPLE=s390x-ibm-linux-gnu
      ;;
    riscv64-linux-gnu)
      CROSS_SYSTEM_PROCESSOR=riscv64
      CROSS_TARGET_ARCHITECTURE=riscv64
      CROSS_MACHINE=riscv64
      CROSS_ARCH=64
      CROSS_JNI_LIBC=
      GNU_TOOLCHAIN_KIND=glibc
      GNU_TOOL_PREFIX=riscv64-linux-gnu
      GNU_APT_PACKAGES=(gcc-riscv64-linux-gnu g++-riscv64-linux-gnu binutils-riscv64-linux-gnu)
      ;;
    *)
      echo "Unsupported ROCKSDB_CROSS_TRIPLE: ${ROCKSDB_CROSS_TRIPLE}"
      exit 1
      ;;
  esac
}

rocksdb_write_ctng_overrides() {
  local config_path="$1"
  local toolchain_root="$2"

  rocksdb_set_kconfig_bool "${config_path}" CT_ALLOW_BUILD_AS_ROOT y
  rocksdb_set_kconfig_bool "${config_path}" CT_ALLOW_BUILD_AS_ROOT_SURE y
  rocksdb_set_kconfig_bool "${config_path}" CT_EXPERIMENTAL y
  rocksdb_set_ctng_version_choice "${config_path}" CT_BINUTILS "${ROCKSDB_GNU_CROSS_BINUTILS_VERSION}"
  rocksdb_set_ctng_version_choice "${config_path}" CT_GCC "${ROCKSDB_GNU_CROSS_GCC_VERSION}"
  rocksdb_set_ctng_version_choice "${config_path}" CT_MUSL "${ROCKSDB_GNU_CROSS_MUSL_VERSION}"
  rocksdb_set_kconfig_value "${config_path}" CT_LOCAL_TARBALLS_DIR "${ROCKSDB_GNU_CROSS_SOURCES_DIR}"
  rocksdb_set_kconfig_value "${config_path}" CT_PREFIX_DIR "${toolchain_root}"
  rocksdb_set_kconfig_bool "${config_path}" CT_SAVE_TARBALLS y
  rocksdb_set_kconfig_bool "${config_path}" CT_LIBC_MUSL y
  rocksdb_set_kconfig_bool "${config_path}" CT_LIBC_GLIBC n
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

}

rocksdb_validate_musl_toolchain() {
  local gcc_path="$1"
  local required
  local resolved

  for required in crt1.o crti.o crtn.o crtbeginS.o crtendS.o libgcc.a libstdc++.a; do
    resolved="$("${gcc_path}" -print-file-name="${required}")"
    if [ -z "${resolved}" ] || [ "${resolved}" = "${required}" ] || [ ! -e "${resolved}" ]; then
      echo "GNU musl cross toolchain is missing ${required} (${resolved})"
      return 1
    fi
  done

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

rocksdb_make_toolchain_id() {
  local cache_key
  local cache_hash
  local short_target

  cache_key="${ROCKSDB_GNU_CROSS_CTNG_VERSION}|${ROCKSDB_GNU_CROSS_BINUTILS_VERSION}|${ROCKSDB_GNU_CROSS_GCC_VERSION}|${ROCKSDB_GNU_CROSS_MUSL_VERSION}|${ROCKSDB_GNU_CROSS_LAYOUT_VERSION}|${ROCKSDB_CROSS_TRIPLE}"
  cache_hash="$(printf '%s' "${cache_key}" | cksum | awk '{print $1}')"
  short_target="$(printf '%s' "${ROCKSDB_CROSS_TRIPLE}" | sed 's/[^A-Za-z0-9]/-/g')"
  printf 'tc-%s-%s\n' "${short_target}" "${cache_hash}"
}

rocksdb_patch_ctng_install() {
  local functions_path="${ROCKSDB_GNU_CROSS_CTNG_ROOT}/share/crosstool-ng/scripts/functions"

  if [ ! -f "${functions_path}" ]; then
    return 0
  fi

  if grep -Fq 'CT_DoExecLog FILE ${CT_TAR:-tar} x -v -f - -C "${dir}" ${components}' "${functions_path}"; then
    return 0
  fi

  sed -i \
    's|CT_DoExecLog FILE tar x -v -f - -C "${dir}" ${components}|CT_DoExecLog FILE ${CT_TAR:-tar} x -v -f - -C "${dir}" ${components}|' \
    "${functions_path}"
}

rocksdb_ensure_ctng() {
  local ctng_bin="${ROCKSDB_GNU_CROSS_CTNG_ROOT}/bin/ct-ng"
  local ctng_src_tar="${ROCKSDB_GNU_CROSS_SOURCES_DIR}/crosstool-ng-${ROCKSDB_GNU_CROSS_CTNG_VERSION}.tar.gz"
  local ctng_src_dir
  local ctng_src_topdir
  local ctng_listing

  if [ -x "${ctng_bin}" ]; then
    rocksdb_patch_ctng_install
    GNU_CTNG_BIN="${ctng_bin}"
    return 0
  fi

  if [ ! -f "${ctng_src_tar}" ]; then
    curl -fsSL "${ROCKSDB_GNU_CROSS_CTNG_URL}" -o "${ctng_src_tar}"
  fi

  ctng_listing="${ROCKSDB_GNU_CROSS_TMP_DIR}/crosstool-ng-${ROCKSDB_GNU_CROSS_CTNG_VERSION}.listing"
  tar -tzf "${ctng_src_tar}" > "${ctng_listing}"
  ctng_src_topdir="$(sed -n '1{s,/.*,,;p;}' "${ctng_listing}")"
  rm -f "${ctng_listing}"
  test -n "${ctng_src_topdir}"
  ctng_src_dir="${ROCKSDB_GNU_CROSS_TMP_DIR}/${ctng_src_topdir}"
  rm -rf "${ctng_src_dir}"
  tar -C "${ROCKSDB_GNU_CROSS_TMP_DIR}" -xzf "${ctng_src_tar}"

  pushd "${ctng_src_dir}" >/dev/null
  ./bootstrap
  ./configure --prefix="${ROCKSDB_GNU_CROSS_CTNG_ROOT}"
  make -j"$(nproc)"
  make install
  popd >/dev/null

  rocksdb_patch_ctng_install
  GNU_CTNG_BIN="${ctng_bin}"
}

rocksdb_ensure_musl_toolchain() {
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
    if [ -n "${ct_target}" ] && rocksdb_validate_musl_toolchain "${cache_toolchain_root}/bin/${ct_target}-gcc"; then
      GNU_TOOL_PREFIX="${ct_target}"
      GNU_TOOLCHAIN_ROOT="${cache_toolchain_root}"
      return 0
    fi

    rm -rf "${cache_toolchain_root}"
  fi

  if [ -f "${local_ready_stamp}" ]; then
    local cached_target=

    cached_target="$(rocksdb_find_toolchain_target "${local_toolchain_root}" || true)"

    if [ -z "${cached_target}" ] || ! rocksdb_validate_musl_toolchain "${local_toolchain_root}/bin/${cached_target}-gcc"; then
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
    "${ctng_bin}" "${GNU_CTNG_SAMPLE}"
    rocksdb_write_ctng_overrides .config "${local_toolchain_root}"
    "${ctng_bin}" olddefconfig
    "${ctng_bin}" build
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
  if [ -z "${ct_target}" ] || ! rocksdb_validate_musl_toolchain "${cache_toolchain_root}/bin/${ct_target}-gcc"; then
    echo "GNU musl cross toolchain cache is invalid after synchronization"
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

  if [ "${GNU_TOOLCHAIN_KIND}" = "glibc" ]; then
    rocksdb_install_apt_packages "${ROCKSDB_GNU_COMMON_PACKAGES[@]}" "${GNU_APT_PACKAGES[@]}"
    toolchain_bin=/usr/bin
  else
    rocksdb_install_apt_packages "${ROCKSDB_GNU_COMMON_PACKAGES[@]}"
    if hash bsdtar 2>/dev/null; then
      export CT_TAR=bsdtar
    fi
    rocksdb_ensure_musl_toolchain
    toolchain_bin="${GNU_TOOLCHAIN_ROOT}/bin"
  fi

  rocksdb_export_cross_toolchain "${toolchain_bin}"

  for tool in "${CC}" "${CXX}" "${AR}" "${AS}" "${LD}" "${NM}" "${OBJDUMP}" "${RANLIB}" "${READELF}" "${STRIP}"; do
    test -x "${tool}"
  done
}
