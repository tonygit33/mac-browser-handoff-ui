#!/usr/bin/env python3
import json, pathlib, sys
p=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else 'obd-bridge/Resources/mazda5-scanner-catalog.json')
d=json.loads(p.read_text(encoding='utf-8'))
assert d['schemaVersion']=='1.2.0'
assert d['counts']['items']==len(d['items'])==458
assert d['counts']['dtcs']==len(d['dtcs'])==6699
assert d['counts']['freeEnabled']==sum(1 for x in d['items'] if x.get('freeEnabled'))==121
assert d['counts']['risky']==sum(1 for x in d['items'] if x.get('risk') in ('medium','high'))==37
assert d['counts']['highRisk']==sum(1 for x in d['items'] if x.get('risk')=='high')==13
for item in d['items']:
    if item.get('freeEnabled'):
        assert item.get('risk')=='low' and item.get('executable') is True and item.get('command'),item
    if item.get('risk') in ('medium','high'):
        assert not item.get('freeEnabled'),item
for command in d['quickSnapshotCommands']:
    assert any(x.get('command')==command and x.get('freeEnabled') for x in d['items']),command
print(f"PASS items={len(d['items'])} free={d['counts']['freeEnabled']} risky={d['counts']['risky']} dtcs={len(d['dtcs'])}")
