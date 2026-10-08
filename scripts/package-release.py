#!/usr/bin/env python3
"""按白名单组装发行包，不包含开发目录、历史或个人状态。"""
import hashlib
import json
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def package(platform):
    with (ROOT / "resources/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("版本号必须为数字三段式")
    output = ROOT / "dist/packages"
    output.mkdir(parents=True, exist_ok=True)
    label = "macOS-universal" if platform == "macos" else "Windows-x64"
    destination = output / f"AI-Exit-Watch-{version}-{label}.zip"
    if destination.exists():
        raise FileExistsError(f"发行包已存在，未覆盖：{destination}")
    with tempfile.TemporaryDirectory(prefix="ai-exit-package-") as temporary:
        stage = Path(temporary) / "AI-Exit-Watch"
        stage.mkdir()
        for name in ("LICENSE", "README.md", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT / name, stage / name)
        # README 使用相对链接；同包保留被链接的指南和图标。
        for name in ("CONTRIBUTING.md", "SECURITY.md", "docs/verification.md", "docs/icon.png", "windows/README.md",
                     "docs/screenshots/README.md", "docs/screenshots/dashboard.png",
                     "docs/screenshots/alert.png", "docs/screenshots/comparison.png"):
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        if platform == "macos":
            source = ROOT / "dist/AI落地安全检测.app"
            allowed = {
                "Contents/Info.plist", "Contents/MacOS/NetworkWatch",
                "Contents/Resources/AppIcon.icns", "Contents/Resources/Assets.car",
                "Contents/Resources/LICENSE", "Contents/Resources/THIRD_PARTY_NOTICES.md",
                "Contents/_CodeSignature/CodeResources",
            }
            actual = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()}
            if actual != allowed or any(p.is_symlink() for p in source.rglob("*")):
                raise ValueError("应用包文件与发行白名单不一致")
            architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(source / "Contents/MacOS/NetworkWatch")], text=True).split()
            if set(architectures) != {"arm64", "x86_64"}:
                raise ValueError("应用不是 arm64 / x86_64 通用包")
            subprocess.run(["codesign", "--verify", "--strict", str(source)], check=True)
            built = plistlib.loads((source / "Contents/Info.plist").read_bytes())
            if built["CFBundleShortVersionString"] != version or built["CFBundleIdentifier"] != info["CFBundleIdentifier"]:
                raise ValueError("构建产物的版本或应用标识与源码不一致")
            shutil.copytree(source, stage / source.name)
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(stage), str(destination)], check=True)
        else:
            source = ROOT / "dist/windows-x64/AIExitWatch.exe"
            data = source.read_bytes()
            pe = struct.unpack_from("<I", data, 0x3C)[0]
            if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0" or struct.unpack_from("<H", data, pe + 4)[0] != 0x8664:
                raise ValueError("不是 Windows x64 可执行文件")
            shutil.copy2(source, stage / source.name)
            shutil.copy2(ROOT / "windows/使用说明.txt", stage / "使用说明.txt")
            assets = json.loads((ROOT / "windows/AIExitWatch/obj/project.assets.json").read_text())
            if assets["project"]["version"] != version:
                raise ValueError("Windows 还原版本与发行版本不一致")
            framework = next(iter(assets["project"]["frameworks"].values()))
            runtime_licenses = {
                "Microsoft.NETCore.App.Runtime.win-x64": ["LICENSE.TXT", "THIRD-PARTY-NOTICES.TXT"],
                "Microsoft.WindowsDesktop.App.Runtime.win-x64": ["LICENSE"],
            }
            notices = stage / "runtime-licenses"
            notices.mkdir()
            for name, files in runtime_licenses.items():
                dependency = next(d for d in framework["downloadDependencies"] if d["name"] == name)
                runtime_version = dependency["version"].strip("[]").split(",")[0].strip()
                for filename in files:
                    license_path = next(
                        Path(p) / name.lower() / runtime_version / filename
                        for p in assets["packageFolders"]
                        if (Path(p) / name.lower() / runtime_version / filename).is_file()
                    )
                    shutil.copy2(license_path, notices / f"{name}-{filename}.txt")
            with zipfile.ZipFile(destination, "x", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
                for file in sorted(stage.rglob("*")):
                    if file.is_file():
                        archive.write(file, "AI-Exit-Watch/" + file.relative_to(stage).as_posix())
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP 完整性校验失败")
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".zip.sha256").write_text(f"{digest}  {destination.name}\n", encoding="utf-8")
    print(f"发行包：{destination.name}\nSHA-256：{digest}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) != 2 or sys.argv[1] not in ("macos", "windows"):
        raise SystemExit("用法：python3 scripts/package-release.py macos|windows")
    package(sys.argv[1])
