#!/usr/bin/env python3
"""Build installable and source archives with the Python standard library."""

import argparse
import json
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory
from zipfile import BadZipFile, ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_MODULES = ("lib", "ui", "generators", "masks", "extensions")
RUNTIME_FILES = ("main.lua", "package.json", "README.md", "LICENSE")
SOURCE_FILES = (
    ".gitignore",
    ".github/workflows/ci.yml",
    "CONTRIBUTING.md",
    "tests/fixtures/indexed-frame-palettes.aseprite",
    "tools/package.py",
)


def runtime_files():
    files = {ROOT / name for name in RUNTIME_FILES}
    for directory in RUNTIME_MODULES:
        files.update((ROOT / directory).rglob("*.lua"))
    manifest = json.loads((ROOT / "package.json").read_text(encoding="utf-8-sig"))
    scripts = manifest.get("contributes", {}).get("scripts", [])
    if not scripts:
        raise ValueError("package.json does not declare an entry script")
    archive_names = {path.relative_to(ROOT).as_posix() for path in files}
    for script in scripts:
        if PurePosixPath(script["path"]).as_posix() not in archive_names:
            raise ValueError(f"entry script is absent from the archive: {script['path']}")
    return files


def write_archive(output, files, prefix=""):
    entries = {
        (PurePosixPath(prefix) / file.relative_to(ROOT).as_posix()).as_posix(): file
        for file in files
    }
    directories = {
        parent.as_posix() + "/"
        for name in entries
        for parent in PurePosixPath(name).parents
        if parent.parts
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent) as temporary_directory:
        temporary = Path(temporary_directory) / output.name
        with ZipFile(temporary, "w") as archive:
            for directory in sorted(directories):
                entry = ZipInfo(directory)
                entry.create_system = 3
                entry.external_attr = (0o40755 << 16) | 0x10
                archive.writestr(entry, b"")
            for name, file in sorted(entries.items()):
                entry = ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                archive.writestr(entry, file.read_bytes(), ZIP_DEFLATED)
        with ZipFile(temporary) as archive:
            invalid_entry = archive.testzip()
            if invalid_entry:
                raise BadZipFile(f"failed CRC check for {invalid_entry}")
        temporary.replace(output)
    print(output.resolve())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "dist" / "Substanceprite.aseprite-extension",
        help="output path for the installable Aseprite extension",
    )
    parser.add_argument(
        "--source-output", type=Path, help="also write a GitHub-ready source ZIP",
    )
    arguments = parser.parse_args()
    if arguments.output.suffix != ".aseprite-extension":
        parser.error("--output must end in .aseprite-extension")
    if arguments.source_output and arguments.source_output.suffix != ".zip":
        parser.error("--source-output must end in .zip")

    try:
        files = runtime_files()
        write_archive(arguments.output, files)
        if arguments.source_output:
            files.update(ROOT / name for name in SOURCE_FILES)
            files.update((ROOT / "tests").rglob("*.lua"))
            files.update((ROOT / "docs" / "demo").glob("*.gif"))
            download = ROOT / "download" / "Substanceprite.aseprite-extension"
            if download.is_file():
                files.add(download)
            write_archive(arguments.source_output, files, prefix="Substanceprite")
    except (OSError, BadZipFile, KeyError, TypeError, ValueError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
