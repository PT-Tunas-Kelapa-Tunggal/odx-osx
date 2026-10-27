# ODX macOS Apple Silicon (arm64) Distribution Pipeline

Automated packaging pipeline producing self-contained, relocatable, App-Sandboxed pre-compiled binary distributions of [ODX (OpenDroneMap)](https://github.com/WebODM/ODX) for macOS Apple Silicon (`arm64`).

## Features
- **Apple Silicon Native**: Built on GitHub Actions `macos-14` (M1/Apple Silicon runners) targeting macOS 14.0+.
- **App Sandbox Ready**: All binaries relinked to `@loader_path` and signed with hardened runtime and child sandbox entitlements (`com.apple.security.app-sandbox` and `com.apple.security.inherit`).
- **Hermetic Runtime**: Bundles isolated Python runtime, GDAL, PROJ, GEOS, OpenCV, Ceres, and compiled ODX C++ SuperBuild modules (`odm_orthophoto`, `dem2mesh`, `dem2points`).
- **Autonomous Release Detection**:
  - Automatically queries upstream [WebODM/ODX](https://github.com/WebODM/ODX) once every 24 hours (and immediately upon pushing to `main`).
  - Automatically triggers new builds for any upstream release tag `>= v3.8.4` that has not yet been built.

## Repository Structure
```
odx-osx/
├── .github/workflows/
│   ├── auto-detect-upstream-release.yml  # Daily cron + push trigger for upstream tags
│   └── build-and-release.yml             # macOS arm64 compilation and packaging workflow
├── Config/
│   ├── min-upstream-version.txt          # Minimum version threshold (v3.8.4)
│   ├── conda-osx-arm64.lock              # Pinned micromamba C++ & Python environment
│   ├── environment.yml                   # Human-readable conda environment spec
│   └── Helper.entitlements               # App Sandbox child entitlements
├── Scripts/
│   └── prepare-distribution-engine.py    # Mach-O relinker, pruner, codesigner, and packager
└── README.md
```

## Workflows

### 1. `auto-detect-upstream-release.yml`
Runs automatically:
- On every push to `main` (initiates the initial build for `v3.8.4` upon repo creation)
- Every 24 hours via cron (`0 0 * * *`)
- Manually via `workflow_dispatch`

### 2. `build-and-release.yml`
Can also be triggered manually using the GitHub CLI:
```bash
gh workflow run build-and-release.yml \
  -f version_tag="v3.8.4" \
  -f upstream_ref="v3.8.4"
```

## Generated Artifacts
Each release publishes:
- `OrthomosaicEngine-macOS-arm64.tar.gz`: Standalone tarball containing `OrthomosaicEngine/` and `OrthomosaicPython`.
- `OrthomosaicEngine-macOS-arm64.tar.gz.sha256`: SHA-256 integrity checksum for verification.
