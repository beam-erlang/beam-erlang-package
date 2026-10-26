"""Qualify package-owned Windows command containment before product tests."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from process import capture


@unittest.skipUnless(os.name == 'nt', 'Windows process ownership')
class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def run_source(self, source, *arguments, timeout=5):
        return capture([sys.executable, '-c', source, *arguments], cwd=self.root,
                       env=os.environ.copy(), timeout=timeout)

    def test_literals_and_status(self):
        arguments = ['', '日本語', 'a"b', 'trail\\', '$(echo unsafe)']
        result = self.run_source('import json,sys;print(json.dumps(sys.argv[1:]));sys.exit(17)', *arguments)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(json.loads(result.stdout), arguments)

    def test_live_descendant_is_rejected_and_stopped(self):
        source = ("import subprocess,sys;subprocess.Popen([sys.executable,'-c',"
                  "'import time;time.sleep(60)'],stdin=subprocess.DEVNULL,"
                  "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.DETACHED_PROCESS)")
        with self.assertRaisesRegex(AssertionError, 'descendants survived'):
            self.run_source(source)

    def test_timeout_stops_owned_tree(self):
        source = ("import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',"
                  "'import time;time.sleep(60)'],stdin=sys.stdin,stdout=sys.stdout,stderr=sys.stderr,"
                  "creationflags=subprocess.DETACHED_PROCESS);time.sleep(60)")
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_source(source, timeout=0.3)


if __name__ == '__main__':
    unittest.main()
