#!/usr/bin/env python3
import argparse, sqlite3, json, pathlib, datetime, os, hashlib

def clean(v):
    if v is None: return None
    if isinstance(v,str):
        v=v.strip()
        return v if v else None
    return v

def ui_state(command, executable, risk, verified=False):
    risk=(risk or 'unknown').lower()
    if command and executable and risk=='low': return 'enabled_free'
    if command and risk in ('medium','high'): return 'locked_risky_free'
    if command and not verified: return 'unverified_reference'
    return 'reference_only'

def locked_reason(state,risk,command):
    if state=='enabled_free': return None
    if state=='locked_risky_free': return f'{risk.capitalize()} risk: visible but disabled in Free version'
    if state=='unverified_reference': return 'Request exists but is not verified on this Mazda 5'
    if not command: return 'No verified transport command yet'
    return 'Reference only'

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('source'); ap.add_argument('output_db'); ap.add_argument('output_json'); a=ap.parse_args()
    src=sqlite3.connect(a.source); src.row_factory=sqlite3.Row
    outp=pathlib.Path(a.output_db); outp.parent.mkdir(parents=True,exist_ok=True)
    if outp.exists(): outp.unlink()
    db=sqlite3.connect(outp)
    db.executescript('''
    PRAGMA journal_mode=DELETE;
    PRAGMA foreign_keys=ON;
    PRAGMA application_id=1295336514;
    PRAGMA user_version=10200;
    CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE scanner_items(
      id TEXT PRIMARY KEY, source_kind TEXT NOT NULL, source_id INTEGER,
      item_kind TEXT NOT NULL, data_status TEXT, module TEXT, category TEXT,
      name TEXT NOT NULL, pid_name TEXT, dtc_code TEXT, command TEXT,
      request_header TEXT, response_header TEXT, formula TEXT, unit TEXT,
      min_value TEXT, max_value TEXT, test_conditions TEXT, interpretation TEXT NOT NULL,
      confidence TEXT NOT NULL, risk TEXT NOT NULL, executable INTEGER NOT NULL,
      free_enabled INTEGER NOT NULL, ui_state TEXT NOT NULL, locked_reason TEXT,
      verified_on_vehicle INTEGER NOT NULL DEFAULT 0,
      vehicle_scope TEXT, engine_scope TEXT, transmission_scope TEXT,
      source_url TEXT, source_title TEXT, source_count INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX idx_scanner_items_pid ON scanner_items(pid_name);
    CREATE INDEX idx_scanner_items_command ON scanner_items(command);
    CREATE INDEX idx_scanner_items_module ON scanner_items(module);
    CREATE INDEX idx_scanner_items_risk ON scanner_items(risk,free_enabled);
    CREATE TABLE pid_profiles(
      id INTEGER PRIMARY KEY,module TEXT,pid_name TEXT,full_name TEXT,value_kind TEXT,unit TEXT,
      access_class TEXT,decode_status TEXT,priority TEXT,exact_standard_command TEXT,
      fallback_commands_json TEXT,formula TEXT,min_value TEXT,max_value TEXT,meaning TEXT,
      diagnostic_use TEXT,caveat TEXT,confidence TEXT,risk TEXT,executable INTEGER
    );
    CREATE TABLE expectations(
      id INTEGER PRIMARY KEY,module TEXT,pid_name TEXT,test_condition TEXT,expected_value TEXT,
      unit TEXT,severity TEXT,applicability TEXT,confidence TEXT,strictness TEXT,source_url TEXT
    );
    CREATE TABLE pid_links(
      id INTEGER PRIMARY KEY,source_pid_name TEXT,target_command TEXT,link_type TEXT,confidence TEXT,notes TEXT
    );
    CREATE TABLE runtime_rules(
      id INTEGER PRIMARY KEY,rule_key TEXT,rule_group TEXT,sequence_no INTEGER,command TEXT,
      response_pattern TEXT,classification TEXT,action TEXT,timeout_ms INTEGER,max_retries INTEGER,
      risk TEXT,enabled INTEGER,notes TEXT
    );
    CREATE TABLE transport_candidates(
      id INTEGER PRIMARY KEY,module TEXT,pid_name TEXT,candidate_label TEXT,service TEXT,identifier TEXT,
      request_command TEXT,positive_response_prefix TEXT,byte_rule TEXT,formula_candidate TEXT,
      unit_candidate TEXT,applicability TEXT,evidence_type TEXT,confidence TEXT,status TEXT,
      verified_on_vehicle INTEGER,executable INTEGER,notes TEXT,source_url TEXT
    );
    CREATE TABLE observed_values(
      id INTEGER PRIMARY KEY,module TEXT,pid_name TEXT,operating_condition TEXT,value_text TEXT,
      min_value REAL,max_value REAL,unit TEXT,observation_class TEXT,confidence TEXT,
      usable_as_threshold INTEGER,diagnostic_interpretation TEXT
    );
    CREATE TABLE dtc_catalog(
      code TEXT PRIMARY KEY,description TEXT,system TEXT,manufacturer_specific INTEGER,
      relation TEXT,confidence TEXT,notes TEXT,description_verified INTEGER NOT NULL
    );
    ''')
    now=datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    meta={
      'schema_version':'1.2.0','content_version':'2026.08.02.1','generated_at':now,
      'vehicle_scope':'Mazda 5 CR 2007 L3 2.3 gasoline','source_database_sha256':hashlib.sha256(pathlib.Path(a.source).read_bytes()).hexdigest(),
      'safety_model':'Show all items; execute only verified low-risk read-only commands in Free version'
    }
    db.executemany('insert into meta values (?,?)',meta.items())
    items=[]
    for r in src.execute('select * from mazda5_sensor_pid_catalog order by id'):
        d=dict(r); risk=(clean(d.get('risk')) or 'unknown').lower(); cmd=clean(d.get('command'))
        exe=1 if d.get('executable') else 0; state=ui_state(cmd,exe,risk,False); free=1 if state=='enabled_free' else 0
        item={
          'id':f"catalog:{d['id']}",'source_kind':'catalog','source_id':d['id'],'item_kind':clean(d.get('record_type')) or 'unknown',
          'data_status':clean(d.get('data_status')),'module':clean(d.get('module')),'category':clean(d.get('category')),
          'name':clean(d.get('name')) or clean(d.get('pid_name')) or f"Item {d['id']}",'pid_name':clean(d.get('pid_name')),
          'dtc_code':clean(d.get('dtc_code')),'command':cmd,'request_header':clean(d.get('request_header')),
          'response_header':clean(d.get('response_header')),'formula':clean(d.get('formula')),'unit':clean(d.get('unit')),
          'min_value':clean(d.get('min_value')),'max_value':clean(d.get('max_value')),'test_conditions':clean(d.get('test_conditions')),
          'interpretation':clean(d.get('interpretation')) or 'No interpretation yet','confidence':clean(d.get('confidence')) or 'unknown',
          'risk':risk,'executable':exe,'free_enabled':free,'ui_state':state,'locked_reason':locked_reason(state,risk,cmd),
          'verified_on_vehicle':0,'vehicle_scope':clean(d.get('model_year_scope')) or clean(d.get('vehicle')),
          'engine_scope':clean(d.get('engine_scope')),'transmission_scope':clean(d.get('transmission_scope')),
          'source_url':clean(d.get('source_url')),'source_title':clean(d.get('source_title')),'source_count':d.get('source_count') or 1
        }
        items.append(item)
    for r in src.execute('select * from mazda5_transport_candidates order by id'):
        d=dict(r); cmd=clean(d.get('request_command')); verified=bool(d.get('verified_on_vehicle')); risk='unknown'
        state='unverified_reference'; item={
          'id':f"transport:{d['id']}",'source_kind':'transport_candidate','source_id':d['id'],'item_kind':'transport_candidate',
          'data_status':clean(d.get('status')),'module':clean(d.get('module')),'category':'Enhanced diagnostics candidate',
          'name':clean(d.get('candidate_label')) or clean(d.get('pid_name')) or f"Transport candidate {d['id']}",
          'pid_name':clean(d.get('pid_name')),'dtc_code':None,'command':cmd,'request_header':None,
          'response_header':clean(d.get('positive_response_prefix')),'formula':clean(d.get('formula_candidate')),
          'unit':clean(d.get('unit_candidate')),'min_value':None,'max_value':None,'test_conditions':clean(d.get('applicability')),
          'interpretation':clean(d.get('notes')) or clean(d.get('evidence_type')) or 'Unverified transport candidate',
          'confidence':clean(d.get('confidence')) or 'unknown','risk':risk,'executable':0,'free_enabled':0,
          'ui_state':state,'locked_reason':'Not verified on this Mazda 5; visible for professional coverage only',
          'verified_on_vehicle':1 if verified else 0,'vehicle_scope':clean(d.get('applicability')),'engine_scope':None,
          'transmission_scope':None,'source_url':clean(d.get('source_url')),'source_title':clean(d.get('evidence_type')),'source_count':1
        }; items.append(item)
    cols=list(items[0])
    db.executemany(f"insert into scanner_items({','.join(cols)}) values ({','.join('?' for _ in cols)})",[[x[c] for c in cols] for x in items])
    copy_specs={
      'pid_profiles':('mazda5_pid_decode_profiles',['id','module','pid_name','full_name','value_kind','unit','access_class','decode_status','priority','exact_standard_command','fallback_commands_json','formula','min_value','max_value','meaning','diagnostic_use','caveat','confidence','risk','executable']),
      'expectations':('mazda5_pid_decode_expectations',['id','module','pid_name','test_condition','expected_value','unit','severity','applicability','confidence','strictness','source_url']),
      'pid_links':('mazda5_pid_decode_links',['id','source_pid_name','target_command','link_type','confidence','notes']),
      'runtime_rules':('mazda5_obd_runtime_rules',['id','rule_key','rule_group','sequence_no','command','response_pattern','classification','action','timeout_ms','max_retries','risk','enabled','notes']),
      'transport_candidates':('mazda5_transport_candidates',['id','module','pid_name','candidate_label','service','identifier','request_command','positive_response_prefix','byte_rule','formula_candidate','unit_candidate','applicability','evidence_type','confidence','status','verified_on_vehicle','executable','notes','source_url']),
      'observed_values':('mazda5_observed_pid_values',['id','module','pid_name','operating_condition','value_text','min_value','max_value','unit','observation_class','confidence','usable_as_threshold','diagnostic_interpretation'])
    }
    for dest,(source,cc) in copy_specs.items():
        rows=src.execute(f"select {','.join(cc)} from {source}").fetchall()
        db.executemany(f"insert into {dest}({','.join(cc)}) values ({','.join('?' for _ in cc)})",[tuple(r) for r in rows])
    # DTC inventory: preserve all direct Mazda5 codes, only trusted selected descriptions.
    dtc_rows=[]
    catalog_dtc={}
    for r in src.execute("select dtc_code,name,interpretation,confidence from mazda5_sensor_pid_catalog where dtc_code is not null and trim(dtc_code)<>'' order by id"):
        code=r['dtc_code'].upper(); catalog_dtc.setdefault(code,dict(r))
    for r in src.execute('select * from mazda5_dtc_best_cache order by code'):
        d=dict(r); code=d['code'].upper(); desc=clean(d.get('description'))
        if not desc and code in catalog_dtc:
            c=catalog_dtc[code]; desc=clean(c.get('name')) or clean(c.get('interpretation'))
        verified=1 if desc else 0
        dtc_rows.append((code,desc,clean(d.get('system')),d.get('manufacturer_specific') or 0,clean(d.get('relation')),clean(d.get('confidence')) or 'unknown',clean(d.get('notes')),verified))
    db.executemany('insert into dtc_catalog values (?,?,?,?,?,?,?,?)',dtc_rows)
    db.commit(); db.execute('vacuum'); db.close()
    # JSON for app. Keep all visible scanner items and a compact DTC lookup.
    db=sqlite3.connect(outp); db.row_factory=sqlite3.Row
    item_json=[]
    for r in db.execute('select * from scanner_items order by case risk when "high" then 0 when "medium" then 1 when "unknown" then 2 else 3 end,module,name'):
        d=dict(r)
        o={'id':d['id'],'kind':d['item_kind'],'module':d['module'],'category':d['category'],'name':d['name'],'pid':d['pid_name'],'dtc':d['dtc_code'],'command':d['command'],'formula':d['formula'],'unit':d['unit'],'min':d['min_value'],'max':d['max_value'],'conditions':d['test_conditions'],'meaning':d['interpretation'],'confidence':d['confidence'],'risk':d['risk'],'executable':bool(d['executable']),'freeEnabled':bool(d['free_enabled']),'state':d['ui_state'],'lockedReason':d['locked_reason'],'verifiedOnVehicle':bool(d['verified_on_vehicle']),'source':d['source_url']}
        item_json.append({k:v for k,v in o.items() if v is not None})
    dtcs={}
    for r in db.execute('select * from dtc_catalog order by code'):
        d=dict(r); o={'description':d['description'],'system':d['system'],'manufacturerSpecific':bool(d['manufacturer_specific']),'relation':d['relation'],'confidence':d['confidence'],'verified':bool(d['description_verified'])}
        dtcs[d['code']]={k:v for k,v in o.items() if v is not None}
    counts={
      'items':db.execute('select count(*) from scanner_items').fetchone()[0],
      'freeEnabled':db.execute('select count(*) from scanner_items where free_enabled=1').fetchone()[0],
      'risky':db.execute("select count(*) from scanner_items where risk in ('medium','high')").fetchone()[0],
      'highRisk':db.execute("select count(*) from scanner_items where risk='high'").fetchone()[0],
      'referenceOnly':db.execute("select count(*) from scanner_items where free_enabled=0").fetchone()[0],
      'dtcs':db.execute('select count(*) from dtc_catalog').fetchone()[0],
      'dtcDescriptions':db.execute('select count(*) from dtc_catalog where description_verified=1').fetchone()[0],
      'profiles':db.execute('select count(*) from pid_profiles').fetchone()[0],
      'expectations':db.execute('select count(*) from expectations').fetchone()[0],
      'rules':db.execute('select count(*) from runtime_rules').fetchone()[0],
      'observedValues':db.execute('select count(*) from observed_values').fetchone()[0]
    }
    quick=['0104','0105','0106','0107','010B','010C','010E','010F','0110','0111','0115','012C','012E','0133','0142','0143','0144','014C']
    payload={'schemaVersion':'1.2.0','contentVersion':'2026.08.02.1','generatedAt':now,'vehicleScope':meta['vehicle_scope'],'counts':counts,'quickSnapshotCommands':quick,'items':item_json,'dtcs':dtcs}
    pathlib.Path(a.output_json).write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    # Final checks
    assert counts['items']==458,counts
    assert counts['dtcs']==6699,counts
    assert all(x.get('risk')=='low' and x.get('command') for x in item_json if x.get('freeEnabled'))
    print(json.dumps({'db':str(outp),'db_bytes':outp.stat().st_size,'json':a.output_json,'json_bytes':pathlib.Path(a.output_json).stat().st_size,'counts':counts,'integrity':db.execute('pragma integrity_check').fetchone()[0],'tables':[r[0] for r in db.execute("select name from sqlite_master where type='table' order by name")]},ensure_ascii=False,indent=2))
main()
