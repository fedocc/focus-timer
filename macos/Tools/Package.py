#!/usr/bin/env python3
"""Package a verified local build, installer and source; never include user state."""
from pathlib import Path
import hashlib
import os
import stat
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'build/Фокус.app'
ARCHIVE = ROOT / 'FocusMenu-macOS-1.3.zip'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    run('/usr/bin/codesign', '--verify', '--strict', APP)
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == '1.3'
    assert info['CFBundleIdentifier'] == 'local.fedor.focus-menu'
    with tempfile.TemporaryDirectory(prefix='focus-package-', dir=ROOT / 'build') as folder:
        package = Path(folder) / 'FocusMenu-macOS'
        package.mkdir()
        shutil.copytree(APP, package / APP.name, symlinks=True)
        shutil.copy2(ROOT / 'Установить_Фокус.command', package)
        shutil.copy2(ROOT / 'README.md', package)
        if (ROOT / 'VERIFICATION.md').exists():
            shutil.copy2(ROOT / 'VERIFICATION.md', package)
        source = package / 'Source'
        source.mkdir()
        for name in ('Sources', 'Tests', 'Tools'):
            shutil.copytree(ROOT / name, source / name, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        for name in ('build.py', 'README.md', 'Установить_Фокус.command', 'VERIFICATION.md'):
            shutil.copy2(ROOT / name, source)
        temporary_archive = Path(folder) / 'package.zip'
        # zipfile marks Cyrillic paths as UTF-8 and preserves executable permission bits.
        with zipfile.ZipFile(temporary_archive, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(package.rglob('*')):
                name = path.relative_to(package.parent).as_posix()
                if path.is_symlink():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, os.readlink(path))
                else:
                    archive.write(path, name)
        with zipfile.ZipFile(temporary_archive) as archive:
            assert archive.testzip() is None
            names = archive.namelist()
            assert not any('settings.json' in name or 'instance.lock' in name for name in names)
            assert not any('WindowService.swift' in name for name in names)
            installer = archive.getinfo('FocusMenu-macOS/Установить_Фокус.command')
            assert (installer.external_attr >> 16) & 0o111, 'installer must be executable'
        # Verify the actual deliverable after extraction, not just its staging directory.
        extracted = Path(folder) / 'extracted'
        run('/usr/bin/ditto', '-x', '-k', temporary_archive, extracted)
        result = extracted / 'FocusMenu-macOS'
        run('/usr/bin/codesign', '--verify', '--strict', result / APP.name)
        run('/bin/zsh', result / 'Установить_Фокус.command', '--check')
        shutil.copy2(temporary_archive, ARCHIVE)
    checksum = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    ARCHIVE.with_suffix('.zip.sha256').write_text(checksum + '  ' + ARCHIVE.name + '\n')
    print(f'{ARCHIVE}\nSHA256 {checksum}')


if __name__ == '__main__':
    main()
