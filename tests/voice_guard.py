#!/usr/bin/env python3
"""Actual model checks with held-out public speech, never the owner's profile.
Usage: ./runtime/bin/python3 tests/voice_guard.py /path/to/fixtures
Fixtures: speechbrain/speechbrain tests/samples/ASR/spk{1,2}_snt{1..6}.wav.
Enrollment uses speaker 1 sentences 1 and 2; verification uses unseen 3–6.
"""
import json
from pathlib import Path
import sys
import tempfile
import unittest
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ears'))
from voice_guard import VoiceGuard
FIXTURES=Path(sys.argv.pop(1)) if len(sys.argv)>1 else ROOT/'tests/fixtures/voice'

class VoiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='F5 voice test ')
        cls.root=Path(cls.temp.name)
        (cls.root/'models').symlink_to(ROOT/'models')
        (cls.root/'state').mkdir()
        cls.config=cls.root/'state/config.json'
        cls.config.write_text(json.dumps({'voiceFilterRequired':True}))
        cls.guard=VoiceGuard(cls.root)
        cls.enrollment=np.tile(np.concatenate([cls.audio(1,1),cls.audio(1,2)]),5)[:16000*30]
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    @staticmethod
    def audio(s,n):
        audio,rate=sf.read(FIXTURES/f'spk{s}_snt{n}.wav',dtype='float32')
        assert rate==16000
        return audio
    def setUp(self):
        self.config.write_text(json.dumps({'voiceFilterRequired':True}))
        self.guard.forget()
    def enroll(self):self.guard.enroll(self.enrollment)
    def test_speech_mask_keeps_soft_onset_and_tail(self):
        class FakeVAD:
            def __init__(self): self.frame=0
            def run(self, outputs, inputs):
                self.frame+=1
                return [np.array([1.0 if self.frame==8 else 0.0]), inputs['state']]
        saved=self.guard.vad
        try:
            self.guard.vad=FakeVAD()
            mask=self.guard.speech_mask(np.zeros(16000,dtype=np.float32))
            onset=7*512
            self.assertTrue(mask[onset-2400:onset+512+2400].all())
            self.assertFalse(mask[:onset-2400].any())
            self.assertFalse(mask[onset+512+2400:].any())
        finally: self.guard.vad=saved

    def test_unenrolled_is_closed(self):
        audio,decision=self.guard.filter(self.audio(1,3))
        self.assertFalse(decision['accepted']);self.assertEqual(len(audio),0)
    def test_heldout_owner_and_other_speaker(self):
        self.enroll()
        for n in range(3,7):
            with self.subTest(owner=n):
                _,d=self.guard.filter(self.audio(1,n));self.assertTrue(d['accepted'])
            with self.subTest(other=n):
                output,d=self.guard.filter(self.audio(2,n));self.assertFalse(d['accepted']);self.assertEqual(float(np.max(np.abs(output))),0)
    def test_quiet_owner_and_other_speaker(self):
        self.enroll()
        for scale in [.25, .08]:
            owner=self.audio(1,3)*scale
            output,d=self.guard.filter(owner)
            self.assertTrue(d['accepted'])
            self.assertGreater(d['accepted_seconds'],2.5)
            _,other=self.guard.filter(self.audio(2,3)*scale)
            self.assertFalse(other['accepted'])
            # The retained onset is restored once one second of context exists.
            output,d=self.guard.filter(owner[:16000])
            self.assertTrue(d['accepted']);self.assertGreater(d['accepted_seconds'],.8)
    def test_background_voice_does_not_inherit_owner_acceptance(self):
        self.enroll();owner=self.audio(1,3);other=self.audio(2,3)
        combined=np.concatenate([owner,np.zeros(8000,dtype=np.float32),other])
        output,d=self.guard.filter(combined)
        self.assertTrue(d['accepted'])
        self.assertEqual(float(np.max(np.abs(output[len(owner)+8000:]))),0)
    def test_noise_and_instrumental_tones_are_rejected(self):
        self.enroll();t=np.arange(16000*4)/16000
        rng=np.random.default_rng(17)
        tones=sum(np.sin(2*np.pi*f*t) for f in [220,277.18,329.63])*.03
        for audio in [np.zeros(len(t),dtype=np.float32),rng.normal(0,.02,len(t)).astype(np.float32),tones.astype(np.float32)]:
            _,d=self.guard.filter(audio);self.assertFalse(d['accepted'])
    def test_noisy_owner_retained(self):
        self.enroll();owner=self.audio(1,3);other=np.resize(self.audio(2,3),len(owner))
        _,d=self.guard.filter(owner+other*.1);self.assertTrue(d['accepted'])
    def test_room_baseline_never_trains_an_identity(self):
        self.guard.calibrate(np.resize(self.audio(2,1),16000*3))
        self.assertTrue(self.guard.calibrated);self.assertFalse(self.guard.status()['enrolled'])
        self.assertFalse(self.guard.profile_path.exists())
    def test_bad_profile_is_closed_and_profile_survives_restart(self):
        self.enroll();second=VoiceGuard(self.root)
        self.assertTrue(second.status()['enrolled'])
        self.guard.profile_path.write_text('{bad profile')
        self.assertFalse(second.status()['enrolled'])
        _,d=second.filter(self.audio(1,3));self.assertFalse(d['accepted'])
    def test_enrollment_rejects_silence_short_audio_and_mixed_speakers(self):
        for audio in [np.zeros(16000*30,dtype=np.float32),self.audio(1,1)]:
            with self.assertRaises(ValueError):self.guard.enroll(audio)
        mixed=np.tile(np.concatenate([self.audio(1,1),self.audio(2,1)]),7)[:16000*30]
        with self.assertRaises(ValueError):self.guard.enroll(mixed)
    def test_shadow_matching_does_not_change_disabled_filter(self):
        self.enroll()
        self.config.write_text(json.dumps({'voiceFilterRequired':False}))
        owner=self.audio(1,3);other=self.audio(2,3)
        _,normal=self.guard.filter(other)
        self.assertEqual(normal['mode'],'off')
        _,shadow=self.guard.filter(owner,required_override=True)
        self.assertTrue(shadow['accepted'])
        _,shadow_other=self.guard.filter(other,required_override=True)
        self.assertFalse(shadow_other['accepted'])
        self.assertFalse(json.loads(self.config.read_text())['voiceFilterRequired'])
    def test_invalid_settings_do_not_disable_filter(self):
        self.config.write_text(json.dumps({'voiceFilterRequired':'yes'}))
        _,d=self.guard.filter(self.audio(1,3));self.assertFalse(d['accepted'])
    def test_voice_profile_private_and_contains_no_audio(self):
        self.enroll();obj=json.loads(self.guard.profile_path.read_text())
        self.assertEqual(self.guard.profile_path.stat().st_mode&0o777,0o600)
        self.assertEqual(set(obj),{'version','model','centroid','enrolled_at','speech_seconds','consistency_min'})
        self.assertEqual(len(obj['centroid']),256)
if __name__=='__main__':unittest.main()
