#!/usr/bin/env python3
"""Rebuild the offline Brave bundle from reviewed upstream checkouts.

Pass a directory containing brave-engine, brave-resources, ublock-assets and
brave-lists. Commit the output to main to make it available to installed apps.
The manifest records exact upstream commits and hashes for reproducibility.
"""
import argparse
from datetime import datetime, timezone
import base64
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import textwrap


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('checkouts', type=Path)
    parser.add_argument('--version', type=int,
                        default=int(datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')),
                        help='Increasing bundle version; defaults to the UTC build timestamp')
    args = parser.parse_args()
    if args.version <= 0:
        parser.error('--version must be positive')
    output = Path(__file__).resolve().parents[1] / 'assets/adblock'
    output.mkdir(parents=True, exist_ok=True)
    roots = args.checkouts
    sources = []
    for name in ['easylist', 'easyprivacy']:
        sources.append(('ublock-assets', f'thirdparties/easylist/{name}.txt', name))
    for name in ['filters', 'unbreak', 'quick-fixes', 'privacy', 'badware', 'resource-abuse']:
        sources.append(('ublock-assets', f'filters/{name}.txt', f'ublock-{name}'))
    for path in ['brave-unbreak.txt', 'brave-lists/brave-specific.txt',
                 'brave-lists/brave-unbreak.txt', 'brave-lists/brave-android-specific.txt']:
        sources.append(('brave-lists', path, path.replace('/', '-').removesuffix('.txt')))
    repo_names = {'ublock-assets': 'uBlockOrigin/uAssets', 'brave-lists': 'brave/adblock-lists',
                  'brave-engine': 'brave/adblock-rust', 'brave-resources': 'brave/adblock-resources'}
    commits = {name: subprocess.check_output(['git', '-C', str(roots/name), 'rev-parse', 'HEAD'], text=True).strip()
               for name in repo_names}

    def expand(path, depth=0):
        if depth > 4:
            raise ValueError('recursive filter include')
        lines = []
        for line in path.read_text().splitlines():
            if line.startswith('!#include '):
                name = line[10:].strip()
                if not re.fullmatch(r'[A-Za-z0-9_-]+\.txt', name):
                    raise ValueError(f'unsupported include: {name}')
                lines.append(expand(path.parent/name, depth+1))
            else:
                lines.append(line)
        return '\n'.join(lines) + '\n'

    lists, descriptors = [], []
    for repo, path, name in sources:
        text = expand(roots/repo/path)
        url = f'https://raw.githubusercontent.com/{repo_names[repo]}/master/{path}'
        digest = hashlib.sha256(text.encode()).hexdigest()
        platforms = ['android'] if name.endswith('android-specific') else []
        lists.append({'name': name, 'text': text, 'permission': 1, 'platforms': platforms})
        descriptors.append({'name': name, 'url': url, 'permission': 1, 'sha256': digest,
                            'commit': commits[repo], 'platforms': platforms})
    resource_sources = [('brave-engine', 'data/brave/brave-resources.json'),
                        ('brave-resources', 'dist/resources.json')]
    resources = {}
    resource_descriptors = []
    for repo, path in resource_sources:
        raw = (roots/repo/path).read_bytes()
        for resource in json.loads(raw):
            resources[resource['name']] = resource
        resource_descriptors.append({'url': f'https://raw.githubusercontent.com/{repo_names[repo]}/master/{path}',
                                     'commit': commits[repo], 'sha256': hashlib.sha256(raw).hexdigest()})
    version = args.version
    bundle = {'schema': 1, 'engine_version': '0.13.6', 'version': version,
              'lists': lists, 'resources': list(resources.values())}
    raw = json.dumps(bundle, ensure_ascii=False, separators=(',', ':')).encode()
    encoded = base64.b64encode(gzip.compress(raw, mtime=0)).decode()
    (output/'bundle.json.gz.b64').write_text('\n'.join(textwrap.wrap(encoded, 100))+'\n')
    manifest = {'schema': 1, 'engine_version': '0.13.6', 'version': version,
                'sha256': hashlib.sha256(raw).hexdigest(), 'lists': descriptors,
                'resources': resource_descriptors}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    (output/'NOTICE.md').write_text('''# Ad blocking components

Cupitor uses Brave Software's adblock-rust 0.13.6 (MPL-2.0).
The native integration is maintained by Cupitor; it is not affiliated with Brave.

The compressed offline bundle contains maintained filter lists and resources:

- Brave adblock-rust resources and adblock-resources: MPL-2.0.
- uBlock Origin/uAssets: GPL-3.0, except files with their own notices.
- EasyList and EasyPrivacy: retain their embedded source/license notices;
  see https://easylist.to/pages/licence.html.
- Brave adblock-lists: retain the licenses and notices of each source list.

The complete source URLs, pinned input commits and SHA-256 digests are recorded
in manifest.json. Filter text and resource metadata are retained in the bundle.
Run scripts/update-brave-bundle.py with upstream checkouts to reproduce it.
''')
    (output/'LICENSE-MPL-2.0.txt').write_bytes((roots/'brave-engine/LICENSE').read_bytes())
    for candidate in ['LICENSE', 'LICENSE.txt']:
        if (roots/'ublock-assets'/candidate).exists():
            (output/'LICENSE-uAssets.txt').write_bytes((roots/'ublock-assets'/candidate).read_bytes())
            break
    print(f'{len(lists)} lists, {len(resources)} resources, {len(raw):,} uncompressed bytes')


if __name__ == '__main__':
    main()
