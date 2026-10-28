#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# Localized Build & Test Runner for ODX Engine (macOS arm64)
# ==============================================================================
# Mirrors the GitHub Actions CI environment locally on Apple Silicon.
# Usage:
#   ./Scripts/local-build-test.sh [options]
#
# Options:
#   --ref <tag/sha>       Upstream ODX git tag or commit SHA (default: v3.8.4)
#   --env-name <name>     Micromamba environment name (default: odx-build-env)
#   --env-prefix <path>   Explicit path to environment prefix
#   --clean               Remove .build directory before starting
#   --package             Also run prepare-distribution-engine.py and tar packaging
#   -h, --help            Show this help message
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Defaults
TARGET_REF="v3.8.4"
if [ -f "Config/min-upstream-version.txt" ]; then
  TARGET_REF="$(cat Config/min-upstream-version.txt | tr -d '[:space:]')"
fi
ENV_NAME="odx-build-env"
ENV_PREFIX=""
DO_CLEAN=false
DO_PACKAGE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      TARGET_REF="$2"
      shift 2
      ;;
    --env-name)
      ENV_NAME="$2"
      shift 2
      ;;
    --env-prefix)
      ENV_PREFIX="$2"
      shift 2
      ;;
    --clean)
      DO_CLEAN=true
      shift
      ;;
    --package)
      DO_PACKAGE=true
      shift
      ;;
    -h|--help)
      grep '^# ' "$0" | cut -c 3-
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

echo "=========================================================="
echo " Starting Local ODX Build & Test"
echo " Target Ref:  $TARGET_REF"
echo " Repo Root:   $REPO_ROOT"
echo "=========================================================="

# 1. Resolve Micromamba Environment
if [ -z "$ENV_PREFIX" ]; then
  if command -v micromamba >/dev/null 2>&1; then
    MAMBA_ROOT="${MAMBA_ROOT_PREFIX:-$HOME/.micromamba}"
    CANDIDATE="$MAMBA_ROOT/envs/$ENV_NAME"
    if [ -d "$CANDIDATE" ]; then
      ENV_PREFIX="$CANDIDATE"
    fi
  fi
fi

if [ -z "$ENV_PREFIX" ] || [ ! -d "$ENV_PREFIX" ]; then
  echo ""
  echo "[-] Target environment '$ENV_NAME' not found."
  echo "    To create it, run:"
  echo "      export MAMBA_ROOT_PREFIX=\"\$HOME/.micromamba\""
  echo "      micromamba create -n $ENV_NAME -f Config/environment.yml -y"
  echo ""
  echo "    Or specify an existing prefix with: --env-prefix /path/to/prefix"
  exit 1
fi

echo "[+] Using environment prefix: $ENV_PREFIX"
PREFIX="$ENV_PREFIX"
export PREFIX
export PYTHONNOUSERSITE=1
export CMAKE_BUILD_PARALLEL_LEVEL="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export CMAKE_PREFIX_PATH="$PREFIX"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export OpenMP_ROOT="$PREFIX"
export MACOSX_DEPLOYMENT_TARGET=14.0

if [ "$DO_CLEAN" = true ]; then
  echo "[+] Cleaning previous .build directory..."
  rm -rf .build
fi

mkdir -p .build

# 2. Checkout Upstream ODX
echo ""
echo "=== [1/6] Checking out Upstream ODX ($TARGET_REF) ==="
if [ ! -d ".build/ODX/.git" ]; then
  git clone --no-checkout https://github.com/WebODM/ODX.git .build/ODX
fi
git -C .build/ODX fetch origin
git -C .build/ODX checkout --detach "$TARGET_REF"
git -C .build/ODX submodule update --init --recursive
COMMIT="$(git -C .build/ODX rev-parse HEAD)"
echo "[+] Upstream resolved to commit: $COMMIT"

# 3. Install pure-Python runtime dependencies
echo ""
echo "=== [2/6] Installing Runtime Pure-Python Dependencies ==="
micromamba run -p "$PREFIX" python -m pip install \
  --no-deps \
  ODMExifRead vmem pyodm Pysolar fpdf2 piexif edt pygltflib

# 4. Pre-clone and patch dem2mesh
echo ""
echo "=== [3/6] Pre-cloning and Patching dem2mesh ==="
mkdir -p .build/ODX/SuperBuild/src/dem2mesh
if [ ! -f ".build/ODX/SuperBuild/src/dem2mesh/CMakeLists.txt" ]; then
  git clone https://github.com/WebODM/dem2mesh.git .build/ODX/SuperBuild/src/dem2mesh
  git -C .build/ODX/SuperBuild/src/dem2mesh checkout 623c8536941175c630fabe4f1352ddc314d98120
fi

# Patch dem2mesh to use -L<prefix>/lib -lomp instead of invalid -fopenmp linker flag
python3 -c "
from pathlib import Path
d2m = Path('.build/ODX/SuperBuild/src/dem2mesh/CMakeLists.txt')
if d2m.exists():
    c = d2m.read_text()
    target = 'set(CMAKE_EXE_LINKER_FLAGS \"\${CMAKE_EXE_LINKER_FLAGS} -fopenmp\")'
    replacement = 'set(CMAKE_EXE_LINKER_FLAGS \"\${CMAKE_EXE_LINKER_FLAGS} -L$PREFIX/lib -lomp\")'
    if target in c:
        c = c.replace(target, replacement)
        d2m.write_text(c)
        print('  [+] Successfully patched dem2mesh/CMakeLists.txt for Apple Clang OpenMP linking')
    else:
        print('  [i] dem2mesh/CMakeLists.txt already patched or target line absent')
"

# 5. Patch SuperBuild CMake files
echo ""
echo "=== [4/6] Patching SuperBuild CMake Configuration ==="
python3 -c "
from pathlib import Path

# Setup clean conda library registration
setup_cmake = Path('.build/ODX/SuperBuild/cmake/ExternalProject-Setup.cmake')
new_setup = '''set(ADD_INTERNAL_LIB_MSG \"--- Adding internal version\")
set(FORCE_BUILD_LIB_MSG \"force build \${ADD_INTERNAL_LIB_MSG}\")
cmake_policy(SET CMP0135 NEW)

macro(SETUP_EXTERNAL_PROJECT name version force_build)
  if(NOT \${force_build})
    find_package(\${name} QUIET)
    if(\${\${name}_FOUND})
      message(STATUS \"\${name} found via system/conda\")
      set(\${name}_DIR \${\${name}_DIR})
      string(TOLOWER \"\${name}\" _name_lower)
      if(NOT TARGET \${_name_lower})
        add_custom_target(\${_name_lower})
      endif()
    else()
      include(External-\${name})
    endif()
  else()
    include(External-\${name})
  endif()
endmacro()

macro(SETUP_EXTERNAL_PROJECT_CUSTOM name)
  include(External-\${name})
endmacro()
'''
setup_cmake.write_text(new_setup)

sb_cmake = Path('.build/ODX/SuperBuild/CMakeLists.txt')
sb_content = sb_cmake.read_text()

# Inject dummy targets for pre-installed conda libraries
dummy_targets = '''
foreach(dep opencv ceres gflags)
  if(NOT TARGET \${dep})
    add_custom_target(\${dep})
  endif()
endforeach()
'''
sb_content = sb_content.replace(
    'SETUP_EXTERNAL_PROJECT(Ceres \${ODM_Ceres_Version} \${ODM_BUILD_Ceres})',
    'SETUP_EXTERNAL_PROJECT(Ceres \${ODM_Ceres_Version} \${ODM_BUILD_Ceres})\n' + dummy_targets
)

# Ensure APPLE_CMAKE_ARGS passes conda paths and OpenMP flags to subprojects
apple_cmake_patch = '''
    set(APPLE_CMAKE_ARGS
        -DCMAKE_PREFIX_PATH=\${CMAKE_PREFIX_PATH}
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        -DOpenMP_ROOT=\${CMAKE_PREFIX_PATH}
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    )
'''
sb_content = sb_content.replace(
    'if (NOT APPLE_CMAKE_ARGS)',
    apple_cmake_patch + '\n    if (NOT APPLE_CMAKE_ARGS)'
)

# Set DOWNLOAD_COMMAND and UPDATE_COMMAND empty for dem2mesh to use pre-cloned patched version
sb_content = sb_content.replace(
    'externalproject_add(dem2mesh\n    GIT_REPOSITORY    https://github.com/WebODM/dem2mesh.git\n    GIT_TAG           623c8536941175c630fabe4f1352ddc314d98120',
    'externalproject_add(dem2mesh\n    DOWNLOAD_COMMAND  \"\"\n    UPDATE_COMMAND    \"\"'
)

# Ensure odm_orthophoto receives APPLE_CMAKE_ARGS so OpenMP is located
sb_content = sb_content.replace(
    'PREFIX            \${SB_BINARY_DIR}/odm_orthophoto\n    SOURCE_DIR        \${SB_SOURCE_DIR}/odm_orthophoto\n    CMAKE_ARGS        -DCMAKE_INSTALL_PREFIX:PATH=\${SB_INSTALL_DIR}\n                      \${WIN32_CMAKE_ARGS} \${WIN32_GDAL_ARGS}\n)',
    'PREFIX            \${SB_BINARY_DIR}/odm_orthophoto\n    SOURCE_DIR        \${SB_SOURCE_DIR}/odm_orthophoto\n    CMAKE_ARGS        -DCMAKE_INSTALL_PREFIX:PATH=\${SB_INSTALL_DIR}\n                      \${WIN32_CMAKE_ARGS} \${WIN32_GDAL_ARGS}\n                      \${APPLE_CMAKE_ARGS}\n)'
)

sb_cmake.write_text(sb_content)
print('  [+] SuperBuild CMake files successfully patched.')
"

# 6. Configure SuperBuild and Compile Native Tools
echo ""
echo "=== [5/6] Building SuperBuild Native Tools (dem2mesh, odm_orthophoto, dem2points) ==="
cd .build/ODX/SuperBuild
mkdir -p build && cd build

cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DOpenMP_ROOT="$PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DODM_BUILD_OpenCV=OFF \
  -DODM_BUILD_Ceres=OFF \
  -DODM_BUILD_GFlags=OFF

cmake --build . --target odm_orthophoto dem2mesh dem2points -j"$CMAKE_BUILD_PARALLEL_LEVEL"

cd "$REPO_ROOT"

# 7. Setup & Build OpenSfM
echo ""
echo "=== [6/6] Setting Up and Building OpenSfM ==="
mkdir -p .build/ODX/SuperBuild/install/bin
if [ ! -f ".build/ODX/SuperBuild/install/bin/opensfm/setup.py" ]; then
  echo "  Cloning OpenSfM into .build/ODX/SuperBuild/install/bin/opensfm..."
  rm -rf .build/ODX/SuperBuild/install/bin/opensfm
  git clone --depth 1 https://github.com/WebODM/OpenSfM.git .build/ODX/SuperBuild/install/bin/opensfm
  git -C .build/ODX/SuperBuild/install/bin/opensfm submodule update --init --recursive
fi

# Patch setup.py to forward CMAKE_ARGS
python3 -c "
from pathlib import Path
setup_file = Path('.build/ODX/SuperBuild/install/bin/opensfm/setup.py')
if setup_file.exists():
    text = setup_file.read_text()
    if 'import shlex' not in text:
        text = text.replace('import subprocess', 'import subprocess\nimport shlex')
        text = text.replace(
            'cmake_command = [',
            'cmake_command = [\"cmake\"] + shlex.split(os.environ.get(\"CMAKE_ARGS\", \"\")) + ['
        )
        text = text.replace(
            '[\"cmake\"] + shlex.split(os.environ.get(\"CMAKE_ARGS\", \"\")) + [\n        \"cmake\",',
            '[\"cmake\"] + shlex.split(os.environ.get(\"CMAKE_ARGS\", \"\")) + ['
        )
        setup_file.write_text(text)
        print('  [+] OpenSfM setup.py patched for CMAKE_ARGS forwarding')
"

micromamba run -p "$PREFIX" /usr/bin/env \
  CC=/usr/bin/clang CXX=/usr/bin/clang++ LD=/usr/bin/ld \
  CFLAGS="-O2 -fPIC -I$PREFIX/include" \
  CXXFLAGS="-O2 -fPIC -stdlib=libc++ -I$PREFIX/include" \
  LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib -fuse-ld=/usr/bin/ld" \
  CMAKE_ARGS="-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ -DCMAKE_LINKER=/usr/bin/ld -DCMAKE_AR=/usr/bin/ar -DCMAKE_RANLIB=/usr/bin/ranlib -DCMAKE_PREFIX_PATH=$PREFIX -DOpenMP_ROOT=$PREFIX -DOPENSFM_BUILD_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0" \
  python -m pip install --no-deps --no-build-isolation -e .build/ODX/SuperBuild/install/bin/opensfm

# 8. Smoke Tests
echo ""
echo "=== Running Smoke Tests ==="
micromamba run -p "$PREFIX" python -c "
import sys
sys.path.insert(0, '.build/ODX')
import rasterio
import cv2
import numpy
import scipy
import PIL
import yaml
import shapely
import pyproj
from stages.odm_app import ODMApp
print('[+] ODX core Python imports verified successfully!')
"

micromamba run -p "$PREFIX" python .build/ODX/run.py --help > /dev/null
echo "[+] ODX CLI entrypoint verified successfully!"

# 9. Optional Packaging
if [ "$DO_PACKAGE" = true ]; then
  echo ""
  echo "=== Packaging Distribution Bundle ==="
  python3 Scripts/prepare-distribution-engine.py \
    --runtime "$PREFIX" \
    --odx .build/ODX \
    --version "$TARGET_REF" \
    --commit "$COMMIT" \
    --output .build/dist \
    --adhoc

  cd .build/dist
  tar -czf ../../OrthomosaicEngine-macOS-arm64.tar.gz OrthomosaicEngine OrthomosaicPython
  cd ../..
  shasum -a 256 OrthomosaicEngine-macOS-arm64.tar.gz > OrthomosaicEngine-macOS-arm64.tar.gz.sha256
  echo "[+] Packaged: OrthomosaicEngine-macOS-arm64.tar.gz ($(du -sh OrthomosaicEngine-macOS-arm64.tar.gz | awk '{print $1}'))"
fi

echo ""
echo "=========================================================="
echo " [SUCCESS] Local ODX build and tests completed cleanly!"
echo "=========================================================="
