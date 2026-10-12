#!/usr/bin/env python3
"""Copy non-system dylibs recursively, then make the .app relocatable."""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
executable = app / "Contents/MacOS/AndroidMTP"
frameworks = app / "Contents/Frameworks"
frameworks.mkdir(parents=True, exist_ok=True)
processed = set()

def run(*args):
    return subprocess.check_output(args, text=True)

def bundle(binary):
    if binary in processed:
        return
    processed.add(binary)
    subprocess.run(["chmod", "u+w", str(binary)], check=True)
    dependencies = [line.strip().split(" (", 1)[0] for line in run("otool", "-L", str(binary)).splitlines()[1:]]
    for dependency in dependencies:
        if dependency.startswith(("/usr/lib/", "/System/Library/", "@")):
            continue
        source = Path(dependency)
        if not source.is_file():
            raise SystemExit(f"Missing dependency: {source}")
        destination = frameworks / source.name
        if not destination.exists():
            shutil.copy2(source.resolve(), destination)
            subprocess.run(["chmod", "u+w", str(destination)], check=True)
            subprocess.run(["install_name_tool", "-id", f"@rpath/{source.name}", str(destination)], check=True)
            bundle(destination)
        subprocess.run(["install_name_tool", "-change", dependency, f"@rpath/{source.name}", str(binary)], check=True)

bundle(executable)
subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(executable)], check=True)
for library in sorted(frameworks.glob("*.dylib")):
    subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True)
