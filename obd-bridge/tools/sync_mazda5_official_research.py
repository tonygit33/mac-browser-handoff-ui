#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, os, socket, sqlite3
from datetime import datetime, timezone
from pathlib import Path

NEW_RELEASE = "1.1.0+2026.08.02.2"
NEW_CONTENT = "2026.08.02.2"

def load_source(path: Path):
    data=json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data.get("records"),list) or len(data["records"])!=13:
        raise ValueError("expected exactly 13 official research records")
    for r in data["records"]:
        forbidden=[r.get("service"),r.get("identifier"),r.get("request_command"),r.get("positive_response_prefix"),r.get("formula_candidate")]
        if any(v not in (None,"") for v in forbidden):
            raise ValueError(f"research record must be non-executable: {r.get('module')} {r.get('pid_name')}")
    return data

def canonical_checksum(previous: str, rows: list[dict], source_sha: str) -> str:
    clean=[]
    for r in rows:
        clean.append({k:r.get(k) for k in sorted(r) if k not in {"id","created_at"}})
    payload={"algorithm":"mazda5-research-chain-v1","previous":previous,"source_sha256":source_sha,"transport_candidates":clean}
    raw=json.dumps(payload,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()

def sync(db_path: Path, source_path: Path):
    source=load_source(source_path)
    source_sha=hashlib.sha256(source_path.read_bytes()).hexdigest()
    db=sqlite3.connect(str(db_path)); db.row_factory=sqlite3.Row
    db.execute("pragma foreign_keys=on")
    inserted=0
    try:
        with db:
            before=db.execute("select count(*) from mazda5_transport_candidates").fetchone()[0]
            created=source["sources"][0]["retrieved_at_utc"]
            for r in source["records"]:
                exists=db.execute("""select 1 from mazda5_transport_candidates
                    where module=? and pid_name=? and ifnull(identifier,'')='' and source_url=?""",
                    (r["module"],r["pid_name"],r["source_url"])).fetchone()
                if exists: continue
                db.execute("""insert into mazda5_transport_candidates(
                    module,pid_name,candidate_label,service,identifier,request_command,positive_response_prefix,
                    byte_rule,formula_candidate,unit_candidate,applicability,evidence_type,source_url,confidence,
                    status,verified_on_vehicle,executable,notes,created_at)
                    values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (r["module"],r["pid_name"],r["candidate_label"],None,None,None,None,None,None,None,
                     r["applicability"],r["evidence_type"],r["source_url"],r["confidence"],r["status"],0,0,
                     r["notes"]+f" Source dataset SHA-256: {source_sha}.",created))
                inserted+=1
            rows=[dict(x) for x in db.execute("select * from mazda5_transport_candidates order by module,pid_name,ifnull(identifier,''),source_url")]
            unsafe=db.execute("select count(*) from mazda5_transport_candidates where executable<>0").fetchone()[0]
            official_with_commands=db.execute("""select count(*) from mazda5_transport_candidates
                where source_url in (?,?,?) and (request_command is not null or service is not null or identifier is not null)""",
                tuple(s["url"] for s in source["sources"])).fetchone()[0]
            if unsafe: raise ValueError(f"executable transport research rows: {unsafe}")
            if official_with_commands: raise ValueError(f"official scope rows unexpectedly contain commands: {official_with_commands}")
            dup=db.execute("""select count(*) from (select module,pid_name,ifnull(identifier,''),source_url,count(*) c
                from mazda5_transport_candidates group by module,pid_name,ifnull(identifier,''),source_url having c>1)""").fetchone()[0]
            if dup: raise ValueError(f"duplicate transport research groups: {dup}")
            prev=db.execute("select * from mazda5_release_manifest where status='production' order by id desc limit 1").fetchone()
            if prev is None: raise ValueError("production release manifest missing")
            checksum=canonical_checksum(prev["logical_checksum"],rows,source_sha)
            existing=db.execute("select id from mazda5_release_manifest where release_version=?",(NEW_RELEASE,)).fetchone()
            if not existing:
                db.execute("update mazda5_release_manifest set status='retired' where status='production'")
                db.execute("""insert into mazda5_release_manifest(
                    release_version,schema_semver,schema_user_version,application_id,content_version,vehicle_scope,status,
                    built_at,build_host,catalog_rows,executable_commands,decode_profiles,expectations,runtime_rules,
                    transport_candidates,external_sources,integrity_check,foreign_key_errors,logical_checksum,notes)
                    values(?,?,?,?,?,?,'production',?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (NEW_RELEASE,prev["schema_semver"],prev["schema_user_version"],prev["application_id"],NEW_CONTENT,
                     prev["vehicle_scope"],datetime.now(timezone.utc).replace(microsecond=0).isoformat(),socket.gethostname(),
                     prev["catalog_rows"],prev["executable_commands"],prev["decode_profiles"],prev["expectations"],
                     prev["runtime_rules"],len(rows),prev["external_sources"],"ok",0,checksum,
                     "Adds official OBDLink/Mazda module-scan coverage as non-executable research with source checksums."))
            integrity=db.execute("pragma integrity_check").fetchone()[0]
            fk=len(db.execute("pragma foreign_key_check").fetchall())
            if integrity!="ok" or fk: raise ValueError(f"database QA failed: integrity={integrity} fk={fk}")
            after=db.execute("select count(*) from mazda5_transport_candidates").fetchone()[0]
        return {"status":"ok","inserted":inserted,"before":before,"after":after,"source_sha256":source_sha,
                "integrity":integrity,"foreign_key_errors":fk,"duplicates":dup,"unsafe_rows":unsafe,"official_rows_with_commands":official_with_commands,
                "release_version":NEW_RELEASE,"logical_checksum":checksum}
    finally: db.close()

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("database",type=Path); ap.add_argument("source",type=Path)
    args=ap.parse_args(); print(json.dumps(sync(args.database,args.source),sort_keys=True)); return 0
if __name__=="__main__": raise SystemExit(main())
