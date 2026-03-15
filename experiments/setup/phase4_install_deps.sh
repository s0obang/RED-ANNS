#!/bin/bash
# ============================================================
# Phase 4: 빌드 의존성 설치
# ============================================================
# ★ 4개 노드 각각에서 실행 ★
# 또는 마스터에서: bash run_on_all_nodes.sh phase4_install_deps.sh
#
# CloudLab Wisconsin 환경 정보:
#   - OS: Ubuntu 22.04.2, GCC 11.4 이미 설치됨
#   - Boost: 1.74 설치됨 → 1.85로 업그레이드 필요
#   - CMake: 미설치 → 설치 필요
#   - MPI: 미설치 → OpenMPI 설치 필요
#   - 디스크: ~57 Gi free (Boost 빌드에 ~2Gi 임시 필요)
#
# 설치 대상:
#   - OpenMPI (mpiexec)
#   - Boost 1.85 (MPI + JSON 컴포넌트, 소스 빌드)
#   - CMake (apt)
#   - MKL (Intel Math Kernel Library)
#   - hwloc, numactl 등
#
# 사용법: sudo bash phase4_install_deps.sh
# ============================================================

set -euo pipefail

echo "=========================================="
echo " Build Dependencies Installation"
echo " (CloudLab Ubuntu 22.04)"
echo "=========================================="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: root 권한이 필요합니다."
    echo "  sudo bash phase4_install_deps.sh"
    exit 1
fi

# ---- 디스크 공간 확인 ----
echo "=== [Pre-check] Disk space ==="
FREE_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
echo "  Available: ${FREE_GB}Gi"
if [ "$FREE_GB" -lt 5 ]; then
    echo "  ⚠️ WARNING: 디스크 공간이 5Gi 미만입니다!"
    echo "  Boost 빌드에 최소 2Gi가 필요합니다."
    read -p "  계속하시겠습니까? (y/n): " CONT
    [ "$CONT" != "y" ] && exit 1
fi
echo ""

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

if command -v mpiexec &>/dev/null; then
    echo "  MPI already installed: $(mpiexec --version 2>/dev/null | head -1)"
else
    apt-get install -y \
        openmpi-bin \
        openmpi-common \
        libopenmpi-dev \
        2>/dev/null

    echo "  → OpenMPI installed"
    echo "  $(mpiexec --version 2>/dev/null | head -1 || echo 'version check failed')"
fi
echo ""

# ---- Step 3: Intel MKL ----
echo "=== [3/5] Intel MKL ==="

if dpkg -l | grep -q "intel-mkl\|intel-oneapi-mkl" 2>/dev/null || [ -d /opt/intel/mkl ] || [ -d /opt/intel/oneapi/mkl ]; then
    echo "  MKL already installed"
else
    echo "  Installing Intel oneAPI MKL..."

    # Intel GPG key 추가
    wget -qO - https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
        gpg --dearmor -o /usr/share/keyrings/intel-oneapi-archive-keyring.gpg 2>/dev/null || true

    echo "deb [signed-by=/usr/share/keyrings/intel-oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | \
        tee /etc/apt/sources.list.d/intel-oneapi.list > /dev/null

    apt-get update -qq 2>/dev/null
    apt-get install -y intel-oneapi-mkl-devel 2>/dev/null || {
        echo "  WARNING: Intel MKL install failed. Trying alternative..."
        apt-get install -y libmkl-dev 2>/dev/null || {
            echo "  WARNING: MKL not available via apt."
            echo "  CMakeLists.txt에서 MKL 없이 빌드 가능한지 확인하세요."
            echo "  See: https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html"
        }
    }
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
    # 모든 유저의 .bashrc에 추가
    for home_dir in /home/*/; do
        if [ -f "$home_dir/.bashrc" ]; then
            if ! grep -q "intel" "$home_dir/.bashrc" 2>/dev/null; then
                echo "source $MKL_SETUP > /dev/null 2>&1 || true" >> "$home_dir/.bashrc" 2>/dev/null || true
            fi
        fi
    done
fi
echo ""

# ---- Step 4: Boost 1.85 (소스 빌드) ----
echo "=== [4/5] Boost 1.85 (source build) ==="
echo "  ⚠️ 기존 Boost 1.74가 있지만 RED-ANNS는 1.85+ 필요"
echo ""

BOOST_VER="1.85.0"
BOOST_DIR="boost_1_85_0"
BOOST_TAR="${BOOST_DIR}.tar.gz"
BOOST_URL="https://archives.boost.io/release/${BOOST_VER}/source/${BOOST_TAR}"
BOOST_INSTALL_PREFIX="/usr/local"

# 이미 1.85 이상 설치되어 있는지 확인
SKIP_BOOST=false
if [ -f "${BOOST_INSTALL_PREFIX}/include/boost/version.hpp" ]; then
    INSTALLED_VER=$(grep "#define BOOST_VERSION " "${BOOST_INSTALL_PREFIX}/include/boost/version.hpp" 2>/dev/null | awk '{print $3}')
    if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" -ge 108500 ] 2>/dev/null; then
        echo "  Boost >= 1.85 already installed (version code: $INSTALLED_VER)"
        SKIP_BOOST=true
    fi
fi

if [ "$SKIP_BOOST" = false ]; then
    cd /tmp

    # 다운로드
    if [ ! -f "$BOOST_TAR" ]; then
        echo "  Downloading Boost ${BOOST_VER} (~140MB..."
        wget -q --show-progress "$BOOST_URL" -O "$BOOST_TAR" || {
            echo "  Primary URL failed, trying mirror..."
            wget -q --show-progress "https://boostorg.jfrog.io/artifactory/main/release/${BOOST_VER}/source/${BOOST_TAR}" -O "$BOOST_TAR"
        }
    fi

    # 압축 해제
    if [ ! -d "$BOOST_DIR" ]; then
        echo "  Extracting..."
        tar xzf "$BOOST_TAR"
    fi

    cd "$BOOST_DIR"

    # MPI 설정 추가
    echo "using mpi ;" > tools/build/src/user-config.jam

    echo "  Running bootstrap..."
    ./bootstrap.sh --prefix="${BOOST_INSTALL_PREFIX}" \
        --with-libraries=mpi,serialization,json,system,filesystem,program_options \
        2>&1 | tail -3

    echo "  Building Boost (5-10 minutes on 32 cores)..."
    ./b2 install -j$(nproc) --prefix="${BOOST_INSTALL_PREFIX}" \
        link=shared threading=multi \
        2>&1 | tail -5

    ldconfig

    echo "  → Boost ${BOOST_VER} installed to ${BOOST_INSTALL_PREFIX}"

    # 정리 (디스크 절약)
    cd /tmp
    rm -rf "$BOOST_DIR" "$BOOST_TAR"
    echo "  → Cleaned up temp files"
fi
echo ""

# ---- Step 5: Python plotting 패키지 ----
echo "=== [5/5] Python packages (plotting) ==="
pip3 install matplotlib numpy pandas 2>/dev/null || {
    echo "  pip3 install failed, trying with --break-system-packages..."
    pip3 install --break-system-packages matplotlib numpy pandas 2>/dev/null || true
}
echo ""

# ---- 검증 ----
echo "=========================================="
echo " Verification"
echo "=========================================="

echo "--- Key binaries ---"
echo "  cmake: $(which cmake 2>/dev/null && cmake --version 2>/dev/null | head -1 || echo 'NOT FOUND')"
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
    dpkg -l 2>/dev/null | grep mkl | head -2 || echo "  WARNING: MKL not found"
echo ""

echo "--- libibverbs ---"
ldconfig -p | grep libibverbs | head -2 || echo "  WARNING: libibverbs not found"
echo ""

echo "--- Disk space after install ---"
df -h / | tail -1
echo ""

echo "=========================================="
echo " Dependencies Installation Complete!"
echo ""
echo " 다음 단계:"
echo "   cd ~/RED-ANNS && bash build.sh"
echo "   (또는 bash phase5_build_and_setup.sh)"
echo "=========================================="
