#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import tomllib
from urllib.parse import quote

VERSION = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
ROOT = Path(__file__).resolve().parents[1]


def check_version(tag: str, root: Path = ROOT):
    if not re.fullmatch('desktop-v' + VERSION, tag):
        raise ValueError('invalid desktop release tag')
    version = tag.removeprefix('desktop-v')
    for name in ['desktop/src-tauri/tauri.conf.json', 'desktop/src-tauri/Cargo.toml',
                 'desktop/package.json']:
        path = root / name
        if path.suffix == '.toml':
            actual = tomllib.loads(path.read_text())['package']['version']
        else:
            actual = json.loads(path.read_text())['version']
        if actual != version:
            raise ValueError(f'{name}: version {actual} differs from tag version {version}')


def make_manifest(version: str, mac_asset: str, mac_sig: Path,
                  windows_asset: str, windows_sig: Path) -> dict:
    if not re.fullmatch(VERSION, version):
        raise ValueError('invalid release version')
    platforms = {}
    for platform, asset, path in [('darwin-aarch64', mac_asset, mac_sig),
                                  ('windows-x86_64', windows_asset, windows_sig)]:
        if not asset or asset in {'.', '..'} or '/' in asset or '\\' in asset:
            raise ValueError('invalid asset name')
        signature = path.read_text()
        if not signature.strip():
            raise ValueError('empty signature')
        platforms[platform] = {
            'signature': signature,
            'url': f'https://github.com/DiAndyW/InfoBank/releases/download/desktop-v{version}/{quote(asset, safe="")}',
        }
    return {'version': version,
            'pub_date': datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'),
            'platforms': platforms}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check-version')
    check.add_argument('tag')
    check.add_argument('--root', type=Path, default=ROOT)
    manifest = commands.add_parser('manifest')
    manifest.add_argument('--version', required=True)
    for platform in ['mac', 'windows']:
        manifest.add_argument(f'--{platform}-asset', required=True)
        manifest.add_argument(f'--{platform}-sig', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'check-version':
            check_version(args.tag, args.root)
        else:
            print(json.dumps(make_manifest(args.version, args.mac_asset, args.mac_sig,
                                           args.windows_asset, args.windows_sig)))
    except (ValueError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
