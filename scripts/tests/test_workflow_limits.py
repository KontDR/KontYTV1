import unittest
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[2]

class WorkflowLimits(unittest.TestCase):
    def test_run_commands_fit_github_limit(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            config = yaml.safe_load(path.read_text())
            for job in config.get('jobs', {}).values():
                for step in job.get('steps', []):
                    if 'run' in step:
                        with self.subTest(workflow=path.name, step=step.get('name')):
                            self.assertLessEqual(len(step['run']), 21000)
