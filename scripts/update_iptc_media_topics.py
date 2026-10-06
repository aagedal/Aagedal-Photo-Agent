#!/usr/bin/env python3
"""Build the multilingual bundled hierarchy from official IPTC JSON-LD.

Download https://cv.iptc.org/newscodes/mediatopic?format=json&lang=all first,
then run: python3 scripts/update_iptc_media_topics.py /path/to/mediatopic.json
Or run without arguments to fetch the latest release directly before packaging.
"""
import json
import sys
from urllib.request import urlopen
from pathlib import Path

if len(sys.argv) > 1:
    source = json.loads(Path(sys.argv[1]).read_text())
else:
    with urlopen('https://cv.iptc.org/newscodes/mediatopic?format=json&lang=all', timeout=30) as response:
        source = json.load(response)
concepts = {c['uri']: c for c in source['conceptSet'] if not c.get('retired')}
children = {}
for uri, concept in concepts.items():
    for parent in concept.get('broader', []):
        children.setdefault(parent, []).append(uri)
visited = set()
def visit(uri, ancestors=frozenset()):
    assert uri in concepts, f'Missing concept: {uri}'
    assert uri not in ancestors, 'Cycle in IPTC hierarchy'
    assert concepts[uri]['prefLabel'].get('en-US') or concepts[uri]['prefLabel'].get('en-GB')
    visited.add(uri)
    for child in children.get(uri, []):
        visit(child, ancestors | {uri})
for uri in source['hasTopConcept']:
    visit(uri)
assert visited == set(concepts), 'Unreachable active concepts'
short = lambda uri: uri.rsplit('/', 1)[-1]
payload = {
    'release': source['dateReleased'],
    'roots': [short(uri) for uri in source['hasTopConcept']],
    'concepts': {short(uri): {'labels': c['prefLabel'], 'children': [short(u) for u in children.get(uri, [])]} for uri, c in concepts.items()},
}
folder = Path(__file__).resolve().parents[1] / 'Aagedal Photo Agent/Resources/KeywordLists'
(folder / 'IPTCMediaTopics.json').write_text(json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
(folder / 'IPTCMediaTopics-LICENSE.txt').write_text(f'''IPTC Media Topics
Copyright 2026 IPTC, International Press Telecommunications Council
Source: https://cv.iptc.org/newscodes/mediatopic?format=json&lang=all
Release: {source['dateReleased']}
License: Creative Commons Attribution 4.0 International (CC BY 4.0)
https://creativecommons.org/licenses/by/4.0/

Adaptation: preferred labels in all supplied languages and broader relationships
converted to a compact hierarchy. Retired concepts omitted. Definitions and
external mappings are not included. Missing translations fall back to English
(US), or English (UK) where the source has no US label.
{len(visited)} active concepts; {len(source['hasTopConcept'])} top-level topics.
IPTC does not endorse this application.
''')
print(f'Wrote {len(visited)} concepts in all {len({k for c in concepts.values() for k in c["prefLabel"]})} IPTC languages/variants')
