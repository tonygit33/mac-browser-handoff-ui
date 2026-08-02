import importlib.util, json, sqlite3, tempfile, unittest
from pathlib import Path
MODULE=Path(__file__).parents[1]/"sync_mazda5_official_research.py"
spec=importlib.util.spec_from_file_location("sync_research",MODULE); mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
SCHEMA="""
create table mazda5_transport_candidates(id integer primary key autoincrement,module text not null,pid_name text not null,candidate_label text not null,service text,identifier text,request_command text,positive_response_prefix text,byte_rule text,formula_candidate text,unit_candidate text,applicability text not null,evidence_type text not null,source_url text not null,confidence text not null,status text not null,verified_on_vehicle integer not null default 0,executable integer not null default 0,notes text not null,created_at text not null,unique(module,pid_name,identifier,source_url));
create table mazda5_release_manifest(id integer primary key autoincrement,release_version text not null unique,schema_semver text not null,schema_user_version integer not null,application_id integer not null,content_version text not null,vehicle_scope text not null,status text not null,built_at text not null,build_host text not null,catalog_rows integer not null,executable_commands integer not null,decode_profiles integer not null,expectations integer not null,runtime_rules integer not null,transport_candidates integer not null,external_sources integer not null,integrity_check text not null,foreign_key_errors integer not null,logical_checksum text not null,notes text not null);
insert into mazda5_release_manifest values(1,'old','1.1.0',10100,1295336514,'old','Mazda 5','production','x','x',442,108,63,66,51,0,6,'ok',0,'abc','old');
"""
class SyncTests(unittest.TestCase):
 def test_atomic_idempotent_non_executable_sync(self):
  root=Path(tempfile.mkdtemp()); db=root/'db.sqlite'; src=Path(__file__).parents[2]/'Resources/VehicleEvidence/official-mazda5-enhanced-diagnostics-2026-08-02/research.json'
  c=sqlite3.connect(db); c.executescript(SCHEMA); c.close()
  first=mod.sync(db,src); second=mod.sync(db,src)
  self.assertEqual(first['inserted'],13); self.assertEqual(first['after'],13); self.assertEqual(second['inserted'],0)
  c=sqlite3.connect(db)
  self.assertEqual(c.execute('select count(*) from mazda5_transport_candidates where executable<>0 or request_command is not null').fetchone()[0],0)
  self.assertEqual(c.execute("select transport_candidates from mazda5_release_manifest where status='production'").fetchone()[0],13)
  self.assertEqual(c.execute("select count(*) from mazda5_release_manifest where status='production'").fetchone()[0],1)
if __name__=='__main__': unittest.main()
