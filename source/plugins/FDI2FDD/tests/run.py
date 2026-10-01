"""Единый запуск тестов; маленький JSON содержит хеш проверенного артефакта."""
import hashlib
import json
from pathlib import Path
import sys
import time
import unittest
from test_plugin import EVIDENCE

root = Path(__file__).resolve().parents[1]
images = ['IS_BASE.FDI', 'voron1/voron1.fdi', 'voron1/voron2.fdi', 'ISDOS.ZIP']
frozen = ['FDI2FDD.ASM', 'fdc.inc', 'image.inc', 'ui.inc', 'sequential.inc',
          'build/FDI2FDD.WMF', 'build/FDI2FDD.sym', 'build/FDI2FDD.lst']
files = frozen + images
before = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}
expected_wmf = '25f20eb5dc9e343fa109d130a1fa6640d4ccdaf4c8c434b65a90ed525bb1e747'
assert before['build/FDI2FDD.WMF'] == expected_wmf, 'not the frozen eighth-pass WMF'
assert (root / 'build/FDI2FDD.WMF').stat().st_size == 7168
started = time.monotonic()
suite = unittest.defaultTestLoader.discover(str(root / 'tests'))
result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
evidence = {'tests': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
            'seconds': round(time.monotonic() - started, 3), 'hardware': False, 'emulator': False,
            'sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}}
evidence.update(EVIDENCE)
evidence['sha256_before'] = before
evidence['input_images_unchanged'] = all(evidence['sha256'][name] == before[name] for name in images)
evidence['frozen_files_unchanged'] = all(evidence['sha256'][name] == before[name] for name in frozen)
evidence['wmf_bytes'] = (root / 'build/FDI2FDD.WMF').stat().st_size
(root / 'build/test-results.json').write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
assert evidence['input_images_unchanged'], 'input image changed during tests'
assert evidence['frozen_files_unchanged'], 'frozen source/build artifact changed during tests'
assert evidence['sha256']['build/FDI2FDD.WMF'] == expected_wmf
sys.exit(not result.wasSuccessful())
