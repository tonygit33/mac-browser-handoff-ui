#!/usr/bin/env python3
"""Discover genuine Mazda5/OBD capture artifacts without ingesting generated reports."""
from __future__ import annotations
import argparse, hashlib, json, os
from pathlib import Path
from typing import Iterable

EXCLUDED_PARTS = {'.git', 'node_modules', '.bridge', 'queue', 'queues', 'results', 'worktrees'}
SESSION_NAMES = {'events.jsonl', 'session.json', 'capture.jsonl', 'obd-session.json'}
TEXT_SUFFIXES = {'.jsonl', '.json', '.csv', '.log', '.txt'}
TOKENS = ('OBDLINK', 'STN2255', 'ATE0', 'ATSP0', '7E8', '0100', '0902')


def excluded(path: Path) -> bool:
    return bool(EXCLUDED_PARTS.intersection(path.parts)) or 'VehicleEvidence' in path.parts


def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
    return h.hexdigest()


def classify(path: Path, sample: str) -> tuple[str,int,list[str]]:
    upper=sample.upper(); hits=[t for t in TOKENS if t in upper]
    if path.name == 'events.jsonl' and '"TYPE"' in upper and '"COMMAND"' in upper:
        return 'obdbridge_events', 100, hits
    if path.name in SESSION_NAMES and hits:
        return 'structured_session', 80, hits
    if path.suffix.lower() in {'.csv','.log','.txt'} and len(hits) >= 2:
        return 'raw_transcript_candidate', 50+len(hits), hits
    return 'non_session', 0, hits


def discover(roots: Iterable[Path], max_bytes: int=100_000_000) -> list[dict]:
    found=[]
    for root in roots:
        root=root.expanduser()
        if not root.exists(): continue
        for p in root.rglob('*'):
            try:
                if not p.is_file() or excluded(p) or p.suffix.lower() not in TEXT_SUFFIXES: continue
                size=p.stat().st_size
                if size == 0 or size > max_bytes: continue
                sample=p.read_bytes()[:2_000_000].decode('utf-8','ignore')
                kind,score,hits=classify(p,sample)
                if score:
                    found.append({'path':str(p),'kind':kind,'score':score,'size':size,'mtime':p.stat().st_mtime,'sha256':sha256(p),'hits':hits})
            except (OSError, UnicodeError):
                continue
    return sorted(found,key=lambda x:(-x['score'],-x['mtime'],x['path']))


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument('roots', nargs='*', type=Path)
    ap.add_argument('--known-sha', action='append', default=[])
    args=ap.parse_args()
    roots=args.roots or [Path.home()/'mac-browser-agent-workspace',Path.home()/'Downloads',Path.home()/'Documents',Path.home()/'Desktop']
    rows=discover(roots)
    known=set(args.known_sha)
    for r in rows: r['already_imported']=r['sha256'] in known
    print(json.dumps({'roots':[str(r.expanduser()) for r in roots],'count':len(rows),'candidates':rows},ensure_ascii=False,sort_keys=True))
    return 0

if __name__ == '__main__': raise SystemExit(main())
