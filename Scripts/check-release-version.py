#!/usr/bin/env python3
"""Read-only preflight: keep the first reserved version for an unreleased batch."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True).strip()


def number(value):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', value):
        raise ValueError(f'Invalid release version: {value!r}')
    return tuple(map(int, value.split('.')))


def validate(root, published_version, published_commit, requested_version=None):
    current = (root / 'VERSION').read_text().strip()
    current_number, published_number = number(current), number(published_version)
    width = max(len(current_number), len(published_number))
    if current_number + (0,) * (width - len(current_number)) <= published_number + (0,) * (width - len(published_number)):
        raise ValueError(f'{current} is already published or older. Reserve one new version for the next release batch.')
    if git(root, 'show', 'HEAD:VERSION').strip() != current:
        raise ValueError('Commit the reserved VERSION before releasing.')
    subprocess.run(['git', 'merge-base', '--is-ancestor', published_commit, 'HEAD'], cwd=root, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    commits = git(root, 'log', '--reverse', '--format=%H', f'{published_commit}..HEAD', '--', 'VERSION').splitlines()
    reserved = None
    for commit in commits:
        value = git(root, 'show', f'{commit}:VERSION').strip()
        if value != published_version:
            reserved = value
            break
    if requested_version is not None:
        number(requested_version)
        if current != requested_version:
            raise ValueError(f'The explicitly requested version {requested_version} does not match VERSION {current}.')
    elif reserved != current:
        raise ValueError(f'Unreleased batch already reserved {reserved}; VERSION is now {current}. '
                         f'Restore {reserved} in a new commit. Follow-up fixes keep the reserved version.')
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='metalnakls/glass')
    parser.add_argument('--requested-version', help='Only use when the user explicitly names a different release version')
    args = parser.parse_args()
    # Resolve the actual published tag, not a local tag or an assumed version.
    release = json.loads(subprocess.check_output(['gh', 'api', f'repos/{args.repo}/releases/latest'], text=True, timeout=40))
    tag = release['tag_name']
    published = tag.removeprefix('v')
    commit = subprocess.check_output(['gh', 'api', f'repos/{args.repo}/commits/{tag}', '--jq', '.sha'],
                                     text=True, timeout=40).strip()
    current = validate(ROOT, published, commit, args.requested_version)
    print(f'Release version verified: {current}; published baseline: {published}.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'Release version check failed: {error}', file=sys.stderr)
        sys.exit(1)
