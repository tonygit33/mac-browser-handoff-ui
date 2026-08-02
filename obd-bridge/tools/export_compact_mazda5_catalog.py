#!/usr/bin/env python3
import argparse, sqlite3, json, pathlib, datetime

def main():
    ap=argparse.ArgumentParser(description='Export the compact Mazda5 scanner SQLite database for the hosted/iPhone UI.')
    ap.add_argument('database'); ap.add_argument('output'); a=ap.parse_args()
    db=sqlite3.connect(a.database); db.row_factory=sqlite3.Row
    meta={r['key']:r['value'] for r in db.execute('select key,value from meta')}
    items=[]
    for r in db.execute('select * from scanner_items order by case risk when "high" then 0 when "medium" then 1 when "unknown" then 2 else 3 end,module,name'):
        d=dict(r); o={'id':d['id'],'kind':d['item_kind'],'module':d['module'],'category':d['category'],'name':d['name'],'pid':d['pid_name'],'dtc':d['dtc_code'],'command':d['command'],'formula':d['formula'],'unit':d['unit'],'min':d['min_value'],'max':d['max_value'],'conditions':d['test_conditions'],'meaning':d['interpretation'],'confidence':d['confidence'],'risk':d['risk'],'executable':bool(d['executable']),'freeEnabled':bool(d['free_enabled']),'state':d['ui_state'],'lockedReason':d['locked_reason'],'verifiedOnVehicle':bool(d['verified_on_vehicle']),'source':d['source_url']}
        items.append({k:v for k,v in o.items() if v is not None})
    dtcs={}
    for r in db.execute('select * from dtc_catalog order by code'):
        d=dict(r); o={'description':d['description'],'system':d['system'],'manufacturerSpecific':bool(d['manufacturer_specific']),'relation':d['relation'],'confidence':d['confidence'],'verified':bool(d['description_verified'])}
        dtcs[d['code']]={k:v for k,v in o.items() if v is not None}
    one=lambda sql:db.execute(sql).fetchone()[0]
    counts={'items':len(items),'freeEnabled':one('select count(*) from scanner_items where free_enabled=1'),'risky':one("select count(*) from scanner_items where risk in ('medium','high')"),'highRisk':one("select count(*) from scanner_items where risk='high'"),'referenceOnly':one('select count(*) from scanner_items where free_enabled=0'),'dtcs':len(dtcs),'dtcDescriptions':one('select count(*) from dtc_catalog where description_verified=1'),'profiles':one('select count(*) from pid_profiles'),'expectations':one('select count(*) from expectations'),'rules':one('select count(*) from runtime_rules'),'observedValues':one('select count(*) from observed_values')}
    quick=['0104','0105','0106','0107','010B','010C','010E','010F','0110','0111','0115','012C','012E','0133','0142','0143','0144','014C']
    payload={'schemaVersion':meta.get('schema_version','1.2.0'),'contentVersion':meta.get('content_version','unknown'),'generatedAt':datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),'vehicleScope':meta.get('vehicle_scope'),'counts':counts,'quickSnapshotCommands':quick,'items':items,'dtcs':dtcs}
    out=pathlib.Path(a.output); out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(payload,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    assert counts['items']==458 and counts['dtcs']==6699
    assert all(x.get('risk')=='low' and x.get('command') for x in items if x.get('freeEnabled'))
    print(json.dumps({'output':str(out),'bytes':out.stat().st_size,'counts':counts},ensure_ascii=False))
main()
