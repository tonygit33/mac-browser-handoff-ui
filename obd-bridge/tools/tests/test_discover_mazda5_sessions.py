import importlib.util, json, tempfile, unittest
from pathlib import Path
P=Path(__file__).parents[1]/'discover_mazda5_sessions.py'
s=importlib.util.spec_from_file_location('discover',P); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
class DiscoveryTests(unittest.TestCase):
  def test_finds_events_and_excludes_bridge_results(self):
    root=Path(tempfile.mkdtemp())
    real=root/'captures'/'s1'; real.mkdir(parents=True)
    (real/'events.jsonl').write_text(json.dumps({'type':'command','command':'0100','response':'7E8 06 41 00'})+'\n')
    fake=root/'.bridge'/'queue'/'results'; fake.mkdir(parents=True)
    (fake/'report.json').write_text('OBDLink 7E8 0100')
    rows=m.discover([root])
    self.assertEqual(len(rows),1); self.assertEqual(rows[0]['kind'],'obdbridge_events')
  def test_requires_multiple_signals_for_text_transcript(self):
    root=Path(tempfile.mkdtemp()); (root/'x.txt').write_text('OBDLink only')
    self.assertEqual(m.discover([root]),[])
if __name__=='__main__': unittest.main()
