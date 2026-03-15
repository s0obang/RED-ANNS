#!/bin/bash
# ============================================================
# Phase 4: 빌드 의존성 설치
# ============================================================
# ★ 4개 노드 각각에서 실행 ★
#
# 설치 대상:
#   - OpenMPI (mpiexec)
#   - Boost 1.85 (소스 빌드, MPI + JSON 컴포넌트 포함)
#   - CMake (최신)
#   - MKL (Intel Math Kernel Library)
#   - hwloc, numactl 등 기타 의존성
#
# 사용법: sudo bash phase4_install_deps.sh
# ============================================================

set -euo pipefail

echo "=========================================="
echo " Build Dependencies Installation"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: root 권한이 필요합니다."
    echo "  sudo bash phase4_install_deps.sh"
    exit 1
fi

# ---- Step 1: 기본 패키지 ----
echo "=== [1/5] Basic packages ==="
apt-get update -qq
apt-get install -y \
    build-essential \
    g++ \
    cmake \
    git \
    wget \
    curl \
    numactl \
    libhwloc-dev \
    hwloc \
    pkg-config \
    python3 \
    python3-pip \
    2>/dev/null

echo "  → Basic packages installed"
echo "  CMake: $(cmake --version | head -1)"
echo "  GCC: $(gcc --version | head -1)"
echo ""

# ---- Step 2: OpenMPI ----
echo "=== [2/5] OpenMPI ==="

# Ubuntu 22.04 패키지 버전 사용
apt-get install -y \
    openmpi-bin \
    openmpi-common \
    libopenmpi-dev \
    2>/dev/null

echo "  → OpenMPI installed"
echo "  $(mpiexec --version 2>/dev/null | head -1 || echo 'version check failed')"
echo ""

# ---- Step 3: Intel MKL ----
echo "=== [3/5] Intel MKL ==="

# Intel oneAPI MKL 설치 (apt repo 추가)
if ! dpkg -l | grep -q intel-mkl 2>/dev/null && ! [ -d /opt/intel/mkl ] && ! [ -d /opt/intel/oneapi/mkl ]; then
    echo "  Installing Intel oneAPI MKL..."

    # Intel GPG key 추가
    wget -qO - https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
        gpg --dearmor -o /usr/share/keyrings/intel-oneapi-archive-keyring.gpg 2>/dev/null || true

    echo "deb [signed-by=/usr/share/keyrings/intel-oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | \
        tee /etc/apt/sources.list.d/intel-oneapi.list > /dev/null

    apt-get update -qq 2>/dev/null
    apt-get install -y intel-oneapi-mkl-devel 2>/dev/null || {
        echo "  WARNING: Intel MKL install failed. Trying alternative..."
        # 대안: apt에서 직접
        apt-get install -y libmkl-dev 2>/dev/null || {
            echo "  WARNING: MKL not available via apt. Manual install may be needed."
            echo "  See: https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html"
        }
    }
else
    echo "  MKL already installed"
fi

# MKL 환경 변수 설정
MKL_SETUP=""
if [ -f /opt/intel/oneapi/setvars.sh ]; then
    MKL_SETUP="/opt/intel/oneapi/setvars.sh"
elif [ -f /opt/intel/mkl/bin/mklvars.sh ]; then
    MKL_SETUP="/opt/intel/mkl/bin/mklvars.sh intel64"
fi

if [ -n "$MKL_SETUP" ]; then
    echo "  → MKL setup script: $MKL_SETUP"
    # .bashrc에 추가
    if ! grep -q "intel" ~/.bashrc 2>/dev/null; then
        echo "source $MKL_SETUP > /dev/null 2>&1 || true" >> /home/*/.bashrc 2>/dev/null || true
    fi
fi
echo ""

# ---- Step 4: Boost 1.85 (소스 빌드) ----
echo "=== [4/5] Boost 1.85 (source build) ==="

BOOST_VER="1.85.0"
BOOST_DIR="boost_1_85_0"
BOOST_TAR="${BOOST_DIR}.tar.gz"
BOOST_URL="https://archives.boost.io/release/${BOOST_VER}/source/${BOOST_TAR}"
BOOST_INSTALL_PREFIX="/usr/local"

# 이미 설치되어 있는지 확인
if [ -f "${BOOST_INSTALL_PREFIX}/include/boost/version.hpp" ]; then
    INSTALLED_VER=$(grep "#define BOOST_VERSION " "${BOOST_INSTALL_PREFIX}/include/boost/version.hpp" | awk '{print $3}')
    echo "  Boost already installed (version code: $INSTALLED_VER)"
    if [ "$INSTALLED_VER" -ge 108500 ] 2>/dev/null; then
        echo "  → Boost >= 1.85, skipping build"
        SKIP_BOOST=true
    else
        echo "  → Boost < 1.85, rebuilding..."
        SKIP_BOOST=false
    fi
else
    SKIP_BOOST=false
fi

if [ "$SKIP_BOOST" = false ]; then
    cd /tmp

    # 다운로드
    if [ ! -f "$BOOST_TAR" ]; then
        echo "  Downloading Boost ${BOOST_VER}..."
        wget -q "$BOOST_URL" -O "$BOOST_TAR" || {
            echo "  Primary URL failed, trying alternative..."
            wget -q "https://boostorg.jfrog.io/artifactory/main/release/${BOOST_VER}/source/${BOOST_TAR}" -O "$BOOST_TAR"
        }
    fi

    # 압축 해제
    if [ ! -d "$BOOST_DIR" ]; then
        echo "  Extracting..."
        tar xzf "$BOOST_TAR"
    fi

    cd "$BOOST_DIR"

    # bootstrap (MPI 포함)
    echo "  Running bootstrap..."
    # MPI 설정 (user-config.jam에 MPI 추가)
    echo "using mpi ;" > tools/build/src/user-config.jam

    ./bootstrap.sh --prefix="${BOOST_INSTALL_PREFIX}" \
        --with-libraries=mpi,serialization,json,system,filesystem,program_options \
        2>&1 | tail -3

    # 빌드 + 설치
    echo "  Building Boost (this takes 5-10 minutes)..."
    ./b2 install -j$(nproc) --prefix="${BOOST_INSTALL_PREFIX}" \
        link=shared threading=multi \
        2>&1 | tail -5

    # ldconfig
    ldconfig

    echo "  → Boost ${BOOST_VER} installed to ${BOOST_INSTALL_PREFIX}"

    # 정리
    cd /tmp
    rm -rf "$BOOST_DIR" "$BOOST_TAR"
fi
echo ""

# ---- Step 5: libibverbs 링크 확인 ----
echo "=== [5/5] Verification ==="

echo "--- Key binaries ---"
echo "  cmake: $(which cmake) → $(cmake --version 2>/dev/null | head -1)"
echo "  mpic++: $(which mpic++ 2>/dev/null || echo 'NOT FOUND')"
echo "  mpiexec: $(which mpiexec 2>/dev/null || echo 'NOT FOUND')"
echo "  numactl: $(which numactl 2>/dev/null || echo 'NOT FOUND')"
echo ""

echo "--- Boost ---"
if [ -f "${BOOST_INSTALL_PREFIX}/include/boost/version.hpp" ]; then
    echo "  Header: ${BOOST_INSTALL_PREFIX}/include/boost/version.hpp"
    grep "BOOST_LIB_VERSION" "${BOOST_INSTALL_PREFIX}/include/boost/version.hpp" | head -1
fi
ls ${BOOST_INSTALL_PREFIX}/lib/libboost_mpi* 2>/dev/null | head -3 || echo "  WARNING: libboost_mpi not found"
echo ""

echo "--- MKL ---"
find /opt/intel -name "libmkl_core*" 2>/dev/null | head -1 || \
    dpkg -l | grep mkl | head -2 || echo "  WARNING: MKL not found"
echo ""

echo "--- libibverbs ---"
ldconfig -p | grep libibverbs | head -2 || echo "  WARNING: libibverbs not found"
echo ""

echo "=========================================="
echo " Dependencies Installation Complete!"
echo ""
echo " 다음 단계: RED-ANNS 빌드"
echo "   cd RED-ANNS && bash build.sh"
echo "=========================================="
