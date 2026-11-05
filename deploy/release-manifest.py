#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
from pathlib import Path


def version_tuple(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value):
        raise ValueError('invalid release version')
    return tuple(map(int, value.split('.')))


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def parse_manifest(data: bytes) -> dict:
    value = json.loads(data, object_pairs_hook=unique_pairs)
    keys = {'format_version', 'version', 'commit', 'os', 'arch', 'filename', 'sha256'}
    if not isinstance(value, dict) or value.keys() != keys:
        raise ValueError('invalid manifest fields')
    version_tuple(value['version'])
    if type(value['format_version']) is not int or value['format_version'] != 1:
        raise ValueError('unsupported manifest format')
    for key, pattern in [('commit', r'[0-9a-f]{40}'), ('sha256', r'[0-9a-f]{64}')]:
        if not isinstance(value[key], str) or not re.fullmatch(pattern, value[key]):
            raise ValueError('invalid manifest identity')
    if (value['os'], value['arch'], value['filename']) != ('linux', 'arm64', 'notebank-server-linux-arm64'):
        raise ValueError('unsupported release target')
    return value


def make_manifest(version: str, commit: str, binary: Path) -> bytes:
    value = dict(format_version=1, version=version, commit=commit, os='linux', arch='arm64',
                 filename='notebank-server-linux-arm64', sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
    data = (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()
    parse_manifest(data)
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('version')
    parser.add_argument('commit')
    parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    import sys
    sys.stdout.buffer.write(make_manifest(args.version, args.commit, args.binary))
