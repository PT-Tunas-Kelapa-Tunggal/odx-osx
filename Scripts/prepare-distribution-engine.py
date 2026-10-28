#!/usr/bin/env python3
"""Prepare a standalone, relocatable ODX Engine distribution for macOS Apple Silicon.

Relinks all Mach-O binaries to relative @loader_path, prunes build headers,
applies sandboxing helper entitlements, and creates the engine distribution bundle.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True)


def is_macho(path: Path) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    magic_numbers = {
        b'\xcf\xfa\xed\xfe',  # 64-bit Mach-O
        b'\xce\xfa\xed\xfe',  # 32-bit Mach-O
        b'\xca\xfe\xba\xbe',  # Universal binary
        b'\xca\xfe\xba\xbf',
    }
    try:
        with path.open('rb') as handle:
            return handle.read(4) in magic_numbers
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path, help='Path to conda/micromamba build prefix')
    parser.add_argument('--odx', required=True, type=Path, help='Path to built ODX checkout')
    parser.add_argument('--version', required=True, help='Release version tag (e.g. v3.8.4)')
    parser.add_argument('--commit', required=True, help='ODX git commit SHA')
    parser.add_argument('--output', required=True, type=Path, help='Target staging directory (.build/dist)')
    parser.add_argument('--identity', default='-', help='Signing identity (defaults to - for ad-hoc)')
    parser.add_argument('--adhoc', action='store_true', help='Force ad-hoc signing for CI builds')
    parser.add_argument('--timestamp', action='store_true', help='Use secure timestamp during signing')

    args = parser.parse_args()
    original_prefix = args.runtime.resolve()
    odx_src = args.odx.resolve()
    output_dir = args.output.resolve()

    if args.adhoc:
        identity = '-'
    else:
        identity = args.identity

    print(f"=== Preparing ODX Engine Distribution ===")
    print(f"Runtime Prefix: {original_prefix}")
    print(f"ODX Source:     {odx_src}")
    print(f"Release Tag:    {args.version}")
    print(f"Commit SHA:     {args.commit}")
    print(f"Output Dir:     {output_dir}")
    print(f"Signing ID:     {identity}")

    output_dir.mkdir(parents=True, exist_ok=True)
    engine_dir = output_dir / 'OrthomosaicEngine'
    if engine_dir.exists():
        shutil.rmtree(engine_dir)
    engine_dir.mkdir(parents=True)

    # 1. Copy runtime environment
    print("\n[1/7] Copying runtime environment...")
    dest_env = engine_dir / 'environment'
    run('/bin/cp', '-cR', str(original_prefix), str(dest_env))

    # 2. Copy ODX source tree
    print("[2/7] Copying ODX source and modules...")
    dest_odx = engine_dir / 'ODX'
    shutil.copytree(
        odx_src,
        dest_odx,
        symlinks=True,
        ignore=shutil.ignore_patterns(
            'build', 'cmake_build', '__pycache__', '.git', '*.egg-info',
            'SuperBuild/build', 'SuperBuild/download', 'SuperBuild/src'
        )
    )

    # 3. Relocate any compiled SuperBuild tools/binaries into environment/bin and lib
    print("[3/7] Staging SuperBuild modules...")
    sb_install = odx_src / 'SuperBuild' / 'install'
    if sb_install.exists():
        sb_bin = sb_install / 'bin'
        if sb_bin.exists():
            dest_bin = dest_env / 'bin'
            for item in sb_bin.glob('*'):
                if item.is_file():
                    shutil.copy2(item, dest_bin / item.name)
                    print(f"  Staged SuperBuild executable: {item.name}")
        sb_lib = sb_install / 'lib'
        if sb_lib.exists():
            dest_lib = dest_env / 'lib'
            for item in sb_lib.glob('*'):
                if item.is_file() and not item.is_symlink():
                    shutil.copy2(item, dest_lib / item.name)
                    print(f"  Staged SuperBuild library: {item.name}")

    # 4. Prune development tools, headers, and compiler artifacts
    print("[4/7] Pruning compiler toolchains, headers, and caches...")
    bin_dir = dest_env / 'bin'
    if bin_dir.is_dir():
        allowed_bins = {
            'python', 'python3', 'python3.10', 'python3.11', 'python3.12',
            'gdalwarp', 'gdal_translate', 'gdalinfo', 'ogr2ogr',
            'odm_orthophoto', 'dem2mesh', 'dem2points', 'poissonrecon',
            'lastools', 'las2las', 'lasinfo', 'fastrasterfilter', 'opensfm'
        }
        for entry in bin_dir.iterdir():
            if entry.name not in allowed_bins and not entry.name.startswith('python3.'):
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()

    # Prune development headers & cmake configs
    for name in ('include', 'libexec', 'compiler_compat', 'lib/clang', 'lib/cmake', 'share/doc', 'share/man'):
        path = dest_env / name
        if path.is_dir():
            shutil.rmtree(path)

    # Clean __pycache__ and static .a libraries
    for cache in engine_dir.rglob('__pycache__'):
        shutil.rmtree(cache)
    for static_lib in engine_dir.rglob('*.a'):
        static_lib.unlink()

    # 5. Make symlinks relative
    print("[5/7] Normalizing symlinks to relative targets...")
    for link in engine_dir.rglob('*'):
        if link.is_symlink():
            try:
                target = os.readlink(link)
                if target.startswith(str(original_prefix) + '/'):
                    dest = dest_env / Path(target).relative_to(original_prefix)
                    link.unlink()
                    link.symlink_to(os.path.relpath(dest, link.parent))
            except Exception as e:
                print(f"  Warning: Could not process symlink {link}: {e}")

    # 6. Relink Mach-O binaries to @loader_path and codesign
    print("[6/7] Rewriting Mach-O rpaths to relative @loader_path and signing...")
    binaries = [p for p in engine_dir.rglob('*') if is_macho(p)]
    print(f"  Found {len(binaries)} Mach-O binaries to relink and sign.")

    # Locate target Python binary
    python_bin = None
    for candidate in ('bin/python3.10', 'bin/python3.11', 'bin/python3.12', 'bin/python3'):
        p = dest_env / candidate
        if p.is_file():
            python_bin = p
            break
    if not python_bin:
        raise RuntimeError("Could not find python binary in destination environment")

    repo_root = Path(__file__).resolve().parent.parent
    entitlements_path = repo_root / 'Config' / 'Helper.entitlements'
    if not entitlements_path.is_file():
        # Fallback to local temporary entitlements
        entitlements_path = output_dir / 'Helper.entitlements'
        entitlements_path.write_text("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.inherit</key>
    <true/>
</dict>
</plist>
""")

    for index, path in enumerate(binaries):
        # Set install name if absolute
        identifiers = [
            line for line in run('/usr/bin/otool', '-D', str(path)).splitlines()
            if line and not line.endswith(':') and '(architecture ' not in line
        ]
        identifier = identifiers[-1] if identifiers else None
        if identifier and identifier.startswith('/'):
            run('/usr/bin/install_name_tool', '-id', '@rpath/' + path.name, str(path))

        # Rewrite absolute LC_RPATHs to relative @loader_path
        commands = run('/usr/bin/otool', '-l', str(path))
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
        for old in dict.fromkeys(rpaths):
            if old.startswith(str(original_prefix) + '/'):
                mapped = dest_env / Path(old).relative_to(original_prefix)
                new = '@loader_path/' + os.path.relpath(mapped, path.parent)
                run('/usr/bin/install_name_tool', '-rpath', old, new, str(path))

        # Rewrite dependent dylibs to relative @loader_path
        for line in run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]:
            if not line.startswith('\t'):
                continue
            dep = line.strip().split(' (compatibility')[0]
            if dep.startswith(str(original_prefix) + '/'):
                mapped = dest_env / Path(dep).relative_to(original_prefix)
                new = '@loader_path/' + os.path.relpath(mapped, path.parent)
                run('/usr/bin/install_name_tool', '-change', dep, new, str(path))

        # Codesign the binary
        sign_cmd = ['/usr/bin/codesign', '--force', '--sign', identity]
        if args.timestamp and identity != '-':
            sign_cmd.append('--timestamp')
        else:
            sign_cmd.append('--timestamp=none')

        if path == python_bin:
            sign_cmd += [
                '--options', 'runtime',
                '--identifier', 'com.hata.ControlDroneMapping.engine.python',
                '--entitlements', str(entitlements_path),
            ]
        run(*(sign_cmd + [str(path)]))

        if (index + 1) % 50 == 0 or (index + 1) == len(binaries):
            print(f"  Processed {index + 1}/{len(binaries)} binaries...")

    # Stage OrthomosaicPython helper executable
    helper_dest = output_dir / 'OrthomosaicPython'
    shutil.copy2(python_bin, helper_dest)
    helper_sign_cmd = [
        '/usr/bin/codesign', '--force', '--sign', identity,
        '--options', 'runtime',
        '--identifier', 'com.hata.ControlDroneMapping.engine.python',
        '--entitlements', str(entitlements_path),
        '--timestamp=none',
        str(helper_dest),
    ]
    run(*helper_sign_cmd)

    # 7. Write engine metadata manifest
    print("\n[7/7] Generating engine.json manifest...")
    manifest = {
        "repository": "https://github.com/WebODM/ODX",
        "engine": "odx",
        "version": args.version,
        "commit": args.commit,
        "architecture": "arm64",
        "packaged": True,
        "formatVersion": 1,
    }
    (engine_dir / 'engine.json').write_text(json.dumps(manifest, indent=2) + '\n')

    print("\n=== ODX Engine Staged Successfully ===")
    print(f"Staged Directory: {engine_dir}")
    print(f"Helper Executable: {helper_dest}")


if __name__ == '__main__':
    main()
