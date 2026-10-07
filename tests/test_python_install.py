"""Exercise the complete installer with a deterministic fake Python toolchain."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / 'install_test_visibility.sh'
FAKE_PYTHON = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as f:
    f.write(json.dumps(args) + '\n')
if args[:2] == ['-m', 'venv']:
    if os.environ.get('FAIL_VENV'):
        sys.exit(1)
    bin_dir = pathlib.Path(args[2]) / 'bin'
    bin_dir.mkdir(parents=True)
    (bin_dir / 'python').symlink_to(pathlib.Path(sys.argv[0]).resolve())
    (bin_dir / 'activate').write_text('export PATH="' + str(bin_dir.resolve()) + ':$PATH"\ndeactivate() { :; }\n')
elif args[:3] == ['-m', 'pip', 'install']:
    if args[-1].split('==')[0] == os.environ.get('FAIL_PACKAGE'):
        print('ERROR: No matching distribution found for ' + args[-1], file=sys.stderr)
        sys.exit(1)
elif args[:3] == ['-m', 'pip', 'show']:
    print('Location: ' + os.environ['PACKAGE_LOCATION'])
    print('Version: 4.15.2')
elif args[0] == '-c':
    if 'platform.python_version' in args[1]:
        print(os.environ['PYTHON_VERSION'])
    else:
        sys.exit('Unexpected Python code: ' + repr(args))
else:
    sys.exit('Unexpected Python args: ' + repr(args))
'''


class PythonInstallTests(unittest.TestCase):
    def run_installer(self, version='3.9.16', override='', modern_default='', fail='', fail_venv=False):
        with tempfile.TemporaryDirectory(prefix='dd-python with spaces-') as root:
            root = Path(root)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            python = bin_dir / 'python'
            python.write_text(FAKE_PYTHON)
            python.chmod(0o755)
            # A bare pip must never be used; it could belong to another interpreter.
            (bin_dir / 'pip').write_text('#!/bin/sh\nexit 99\n')
            (bin_dir / 'pip').chmod(0o755)
            packages = root / 'site packages'
            packages.mkdir()
            log = root / 'calls.jsonl'
            env = {k: v for k, v in os.environ.items() if not k.startswith(('DD_', 'PYTHON', 'PYTEST'))}
            env.update(PATH=str(bin_dir) + os.pathsep + env['PATH'],
                       CALL_LOG=str(log), PACKAGE_LOCATION=str(packages),
                       PYTHON_VERSION=version, FAIL_PACKAGE=fail,
                       DD_CIVISIBILITY_INSTRUMENTATION_LANGUAGES='python',
                       DD_TRACER_FOLDER='.datadog',
                       DD_SET_TRACER_VERSION_PYTHON='4.15.2',
                       DD_SET_COVERAGE_VERSION_PYTHON=override,
                       DD_DEFAULT_COVERAGE_VERSION_PYTHON=modern_default)
            if fail_venv:
                env['FAIL_VENV'] = '1'
            result = subprocess.run(['bash', str(INSTALLER)], cwd=root, env=env,
                                    capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            return result, calls

    def assert_success(self, result, calls, expected):
        self.assertEqual(result.returncode, 0, result.stderr)
        requirements = [args[-1] for args in calls if args[:3] == ['-m', 'pip', 'install']]
        self.assertEqual(requirements, ['ddtrace==4.15.2', 'coverage==' + expected])
        self.assertIn('DD_COVERAGE_VERSION_PYTHON=' + expected, result.stdout)
        self.assertIn('DD_TRACER_VERSION_PYTHON=4.15.2', result.stdout)
        self.assertIn('PYTEST_ADDOPTS=--ddtrace', result.stdout)
        self.assertIn('DD_CIVISIBILITY_ENABLED=true', result.stdout)
        self.assertIn('site packages', result.stdout)
        self.assertNotIn('Error:', result.stderr)

    def test_interpreter_defaults(self):
        for minor in range(9, 15):
            with self.subTest(minor=minor):
                self.assert_success(*self.run_installer('3.%s.16' % minor, modern_default='7.16.1'),
                                    '7.10.7' if minor == 9 else '7.16.1')

    def test_standalone_installer_preserves_modern_pin(self):
        self.assert_success(*self.run_installer('3.10.16'), '7.13.5')

    def test_explicit_overrides_win_on_all_supported_interpreters(self):
        for minor in range(9, 15):
            with self.subTest(minor=minor):
                self.assert_success(*self.run_installer('3.%s.16' % minor, override='7.10.6',
                                                       modern_default='7.16.1'), '7.10.6')

    def test_coverage_failure_reports_actual_dependency_without_fallback(self):
        result, calls = self.run_installer(override='7.16.1', fail='coverage')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not install coverage==7.16.1 for Python 3.9.16', result.stderr)
        self.assertIn('No matching distribution found for coverage==7.16.1', result.stderr)
        self.assertNotIn('Could not install ddtrace', result.stderr)
        self.assertEqual(len([a for a in calls if a[:3] == ['-m', 'pip', 'install']]), 2)
        self.assertEqual(result.stdout, '')

    def test_default_coverage_failure_is_not_swallowed(self):
        result, _ = self.run_installer(fail='coverage')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('coverage==7.10.7', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_tracer_failure_stops_before_coverage(self):
        result, calls = self.run_installer(fail='ddtrace')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not install ddtrace==4.15.2 for Python 3.9.16', result.stderr)
        self.assertEqual(len([a for a in calls if a[:3] == ['-m', 'pip', 'install']]), 1)
        self.assertEqual(result.stdout, '')

    def test_venv_failure_stops_before_installation(self):
        result, calls = self.run_installer(fail_venv=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not create the Python instrumentation environment', result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
