import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from recovery import decide

class Recovery(unittest.TestCase):
    def setUp(self): self.idle=dict(enabled=True,capturing=False,dictation_open=False,finishing=False,pending_text=False)
    def test_running_healthy_is_not_restarted(self):self.assertIsNone(decide(self.idle,2,True,0,1000))
    def test_stale_idle_helper_restarts(self):self.assertEqual(decide(self.idle,31,True,0,1000),'com.f5')
    def test_ears_require_three_failures(self):
        self.assertIsNone(decide(self.idle,2,False,2,1000))
        self.assertEqual(decide(self.idle,2,False,3,1000),'com.f5.ears')
    def test_no_restart_during_capture_edit_delivery_or_unknown_state(self):
        for key in ['capturing','dictation_open','finishing','pending_text']:
            self.assertIsNone(decide(self.idle|{key:True},99,False,9,1000))
        self.assertIsNone(decide({},99,False,9,1000))
    def test_cooldown_and_disabled(self):
        self.assertIsNone(decide(self.idle,99,False,9,200))
        self.assertIsNone(decide(self.idle|{'enabled':False},99,False,9,1000))
if __name__=='__main__':unittest.main()
