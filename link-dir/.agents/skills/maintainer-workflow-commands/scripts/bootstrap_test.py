"""Behavior tests for the internal workflow generator; no network or host tools."""
import shutil
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / 'scripts/bootstrap'
LANGS = ('bash', 'ruby', 'js', 'go', 'java')
COMMANDS = ('setup', 'dev', 'test', 'lint', 'deps', 'workflows', 'troubleshoot', 'changelog', 'release')


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.project = Path(self.tmp.name) / 'project'

    def generate(self, languages='js,java', files=','.join(COMMANDS), output=None):
        return subprocess.run([str(BOOTSTRAP), '--files=' + files, '--lang=' + languages,
                               '--output=' + str(output or self.project)],
                              text=True, capture_output=True)

    def run_script(self, name, *args, env=None):
        return subprocess.run([str(self.project / 'bin' / name), *args],
                              cwd=self.project, env=env, text=True, capture_output=True)

    def test_every_selection_has_only_selected_languages(self):
        for languages in [*[(x,) for x in LANGS], ('js', 'java'), LANGS]:
            with self.subTest(languages=languages):
                output = Path(self.tmp.name) / '-'.join(languages)
                result = self.generate(','.join(languages), output=output)
                self.assertEqual(0, result.returncode, result.stderr)
                for path in (output / 'bin').rglob('*'):
                    if not path.is_file():
                        continue
                    source = path.read_text()
                    syntax = subprocess.run(['bash', '-n', str(path)], capture_output=True, text=True)
                    self.assertEqual(0, syntax.returncode, str(path) + syntax.stderr)
                    for excluded in set(LANGS) - set(languages):
                        pattern = (r'--bash|(?:test|lint|setup|deps)_bash|[FP]_bash'
                                   if excluded == 'bash' else
                                   r'--go|(?:test|lint|setup|deps)_go|go\.mod|go (?:test|run|vet|get)|gofmt'
                                   if excluded == 'go' else r'(?<![A-Za-z])' + excluded + r'(?![A-Za-z])')
                        self.assertNotRegex(source, pattern, str(path))
                help_text = subprocess.check_output([str(output / 'bin/test'), '--help'], text=True)
                for language in languages:
                    self.assertIn('--' + language, help_text)

    def test_selected_commands_and_no_overwrite(self):
        self.assertEqual(0, self.generate(files='test,lint').returncode)
        self.assertEqual({'test', 'lint', 'lib'}, {x.name for x in (self.project / 'bin').iterdir()})
        original = (self.project / 'bin/test').read_bytes()
        result = self.generate(files='setup,test')
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.project / 'bin/setup').exists())
        self.assertEqual(original, (self.project / 'bin/test').read_bytes())

    def test_invalid_arguments_write_nothing(self):
        for languages, files in [('java,wat', 'test'), ('java', '../test'), ('', 'test')]:
            result = self.generate(languages, files)
            self.assertEqual(2, result.returncode, result.stderr)
            self.assertFalse(self.project.exists())

    def test_sh_alias_and_excluded_flag(self):
        self.assertEqual(0, self.generate('sh', 'test').returncode)
        self.assertIn('--bash', self.run_script('test', '--help').stdout)
        self.assertEqual(2, self.run_script('test', '--java').returncode)

    def test_java_js_run_and_fail_independently(self):
        self.assertEqual(0, self.generate(files='test,lint,setup,deps').returncode)
        (self.project / 'pom.xml').write_text('<project/>')
        (self.project / 'package.json').write_text('{"scripts":{"test":"unused"}}')
        stubs = self.project / 'stubs'
        stubs.mkdir()
        for tool, body in [('mvn', 'echo maven-ran; exit 1'), ('npm', 'echo npm-ran')]:
            path = stubs / tool
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o755)
        result = self.run_script('test', env={**os.environ, 'PATH': str(stubs) + ':/usr/bin:/bin'})
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn('maven-ran', result.stdout)
        self.assertIn('npm-ran', result.stdout)
        self.assertIn('FAIL', result.stdout)

    def test_bash_discovers_underscore_test_names(self):
        self.assertEqual(0, self.generate('bash', 'test').returncode)
        (self.project / 'test').mkdir()
        path = self.project / 'test/thing_test.sh'
        path.write_text('#!/bin/bash\necho underscore-test-ran\n')
        result = self.run_script('test', '--bash')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('underscore-test-ran', result.stdout)
        result = self.run_script('test', '--dry-run', 'test')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('thing_test.sh', result.stdout)

    def test_go_root_path_selects_only_root_package(self):
        self.assertEqual(0, self.generate('go', 'test').returncode)
        (self.project / 'go.mod').touch()
        (self.project / 'thing_test.go').touch()
        result = self.run_script('test', '--dry-run', 'thing_test.go')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('+ go test . -count=1 -race', result.stdout)
        self.assertNotIn('./...', result.stdout)

    def test_ruby_rake_path_is_a_test_selector(self):
        self.assertEqual(0, self.generate('ruby', 'test').returncode)
        (self.project / 'Gemfile').touch()
        (self.project / 'test').mkdir()
        (self.project / 'test/thing_test.rb').touch()
        result = self.run_script('test', '--dry-run', 'test/thing_test.rb')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('+ bundle exec rake test TEST=test/thing_test.rb', result.stdout)

    def test_verbose_is_only_available_to_suites_that_use_it(self):
        self.assertEqual(0, self.generate('go', 'test').returncode)
        (self.project / 'go.mod').touch()
        result = self.run_script('test', '--dry-run', env={**os.environ, 'VERBOSE': '1'})
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('-v', result.stdout)
        other = Path(self.tmp.name) / 'java-js'
        self.assertEqual(0, self.generate('java,js', 'test', output=other).returncode)
        result = subprocess.run([str(other / 'bin/test'), '--verbose'], text=True, capture_output=True)
        self.assertEqual(2, result.returncode)

    def test_deps_skips_shell_without_losing_selected_languages(self):
        self.assertEqual(0, self.generate('bash,java,js', 'deps').returncode)
        (self.project / 'pom.xml').touch()
        (self.project / 'package.json').touch()
        (self.project / 'bin/tool.sh').touch()
        result = self.run_script('deps', '--dry-run')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('npm-check-updates', result.stdout)
        self.assertIn('versions:display-dependency-updates', result.stdout)
        self.assertNotIn('deps_bash', result.stdout + result.stderr)

    def test_workflow_flags_do_not_leak_between_commands(self):
        self.assertEqual(0, self.generate('java,js', 'setup,test,lint,deps').returncode)
        for command, flag in [('setup', '--java'), ('setup', '--autofix'), ('test', '--check'),
                              ('lint', '--patch'), ('deps', '--autofix'), ('deps', '--verbose')]:
            result = self.run_script(command, flag)
            self.assertEqual(2, result.returncode, (command, flag, result.stdout, result.stderr))
        for command in ('setup', 'test', 'lint', 'deps'):
            self.assertEqual(0, self.run_script(command, '--help').returncode)

    def test_batch_failure_precedence_and_continuation(self):
        self.assertEqual(0, self.generate('java,js', 'test').returncode)
        (self.project / 'pom.xml').touch()
        (self.project / 'package.json').touch()
        stubs = self.project / 'stubs'
        stubs.mkdir()
        for npm_status, mvn_status, expected in [(127, 1, 1), (1, 127, 1), (0, 127, 9), (0, 0, 0)]:
            for name, status in [('npm', npm_status), ('mvn', mvn_status)]:
                path = stubs / name
                path.write_text('#!/bin/bash\necho ' + name + '-ran\nexit ' + str(status) + '\n')
                path.chmod(0o755)
            result = self.run_script('test', env={**os.environ, 'PATH': str(stubs) + ':/usr/bin:/bin'})
            self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
            self.assertIn('npm-ran', result.stdout)
            self.assertIn('mvn-ran', result.stdout)

    def test_troubleshoot_is_only_a_placeholder(self):
        self.assertEqual(0, self.generate(files='troubleshoot').returncode)
        for target in ('local', 'production'):
            result = subprocess.run(['/bin/bash', str(self.project / 'bin/troubleshoot'), target],
                                    env={'PATH': '/nonexistent'}, capture_output=True, text=True)
            self.assertEqual(0, result.returncode)
            self.assertIn('empty for now', result.stdout)
        self.assertEqual(2, self.run_script('troubleshoot').returncode)


class ReleaseTests(unittest.TestCase):
    generate = BootstrapTests.generate
    run_script = BootstrapTests.run_script
    # Reuse fixtures, but do not inherit the generator cases a second time.
    def setUp(self):
        BootstrapTests.setUp(self)
        result = self.generate('java', 'release,changelog')
        self.assertEqual(0, result.returncode, result.stderr)
        for name in ('lint', 'test'):
            path = self.project / 'bin' / name
            path.write_text('#!/bin/bash\necho ' + name + ' >> "$RELEASE_CALLS"\n')
            path.chmod(0o755)
        (self.project / 'CHANGELOG.md').write_text('# Changelog\n\n## [Unreleased]\n\n- User notes\n\n## [1.0.0] - 2026-01-01\n\n- Old notes\n')
        self.git = shutil.which('git')
        self.git_run('init', '-q', '-b', 'main')
        for key, value in [('user.name', 'Test'), ('user.email', 'test@example.invalid'),
                           ('commit.gpgsign', 'false'), ('tag.gpgsign', 'false'), ('core.hooksPath', '/dev/null')]:
            self.git_run('config', key, value)
        self.git_run('add', '.')
        self.git_run('commit', '-qm', 'chore: initial')
        self.git_run('tag', 'v1.0.0')
        self.git_run('commit', '-q', '--allow-empty', '-m', 'feat: export')
        self.head = self.git_run('rev-parse', 'HEAD').stdout.strip()
        stubs = Path(self.tmp.name) / 'stubs'
        stubs.mkdir()
        git_stub = stubs / 'git'
        git_stub.write_text('#!/bin/bash\ncase "$1" in\n  ls-remote)\n    if [[ "$*" == *--heads* ]]; then\n      printf \'%s\\trefs/heads/main\\n\' "$RELEASE_TEST_HEAD"\n    else\n      exit 2\n    fi\n    ;;\n  push) echo push >> "$RELEASE_CALLS" ;;\n  fetch) echo unexpected-fetch >> "$RELEASE_CALLS"; exit 1 ;;\n  *) exec "$REAL_GIT" "$@" ;;\nesac\n')
        gh_stub = stubs / 'gh'
        gh_stub.write_text('#!/bin/bash\necho "gh $*" >> "$RELEASE_CALLS"\ncase "$1 $2" in\n  \'auth status\') exit "${RELEASE_AUTH_STATUS:-0}" ;;\n  \'run list\') echo 123 ;;\n  \'run watch\') exit 0 ;;\n  \'release view\') echo https://example.invalid/releases/tag/v1.1.0 ;;\n  *) exit 1 ;;\nesac\n')
        git_stub.chmod(0o755)
        gh_stub.chmod(0o755)
        self.calls = Path(self.tmp.name) / 'calls'
        self.env = {**os.environ, 'PATH': str(stubs) + ':/usr/bin:/bin', 'REAL_GIT': self.git,
                    'RELEASE_TEST_HEAD': self.head, 'RELEASE_CALLS': str(self.calls),
                    'RELEASE_RUN_WAIT_SECONDS': '0', 'RELEASE_RUN_POLL_SECONDS': '0',
                    'RELEASE_DATE': '2026-11-14'}

    def git_run(self, *args):
        return subprocess.run([self.git, '-C', str(self.project), *args], check=True, text=True, capture_output=True)

    def release(self, *args, answer=''):
        return subprocess.run([str(self.project / 'bin/release'), *args], cwd=self.project,
                              env=self.env, input=answer, text=True, capture_output=True)

    def test_dry_run_is_read_only_and_derives_version(self):
        before = (self.project / 'CHANGELOG.md').read_bytes()
        result = self.release('--dry-run')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn('v1.1.0', result.stdout)
        self.assertIn('git push --atomic origin main', result.stdout)
        self.assertEqual(before, (self.project / 'CHANGELOG.md').read_bytes())
        self.assertEqual(self.head, self.git_run('rev-parse', 'HEAD').stdout.strip())
        self.assertEqual('v1.0.0', self.git_run('tag').stdout.strip())
        self.assertNotIn('unexpected-fetch', self.calls.read_text())
        self.assertNotIn('push', self.calls.read_text())

    def test_release_moves_notes_tags_pushes_and_watches(self):
        result = self.release('--yes')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        notes = (self.project / 'CHANGELOG.md').read_text()
        self.assertIn('## [Unreleased]\n\n## [1.1.0] - 2026-11-14', notes)
        self.assertIn('- User notes', notes)
        self.assertIn('v1.1.0', self.git_run('tag').stdout)
        calls = self.calls.read_text()
        self.assertIn('lint\ntest\npush', calls)
        self.assertIn('gh run watch 123 --exit-status', calls)
        self.assertEqual('', self.git_run('status', '--porcelain').stdout)

    def test_decline_keeps_local_tag_without_push(self):
        result = self.release(answer='n\n')
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertIn('v1.1.0', self.git_run('tag').stdout)
        self.assertNotIn('push', self.calls.read_text())

    def test_explicit_prerelease_and_no_releasable_commits(self):
        self.git_run('tag', 'v1.1.0')
        result = self.release('--dry-run')
        self.assertEqual(1, result.returncode)
        result = self.release('--dry-run', '2.0.0-rc.3')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn('pre-release', result.stdout)
        self.assertEqual(2, self.release('--dry-run', 'v2.0.0').returncode)

    def test_release_accepts_build_metadata(self):
        for version in ('1.1.0+build.7', '1.1.0-rc.3+build.7', '1.1.0+build-meta'):
            result = self.release('--dry-run', version)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn('v' + version, result.stdout)
        self.assertNotIn('pre-release', self.release('--dry-run', '1.1.0+build-meta').stdout)

    def test_validation_cannot_add_files_to_release_commit(self):
        test = self.project / 'bin/test'
        test.write_text('#!/bin/bash\necho generated > source.txt\ngit add source.txt\n')
        self.git_run('add', 'bin/test')
        self.git_run('commit', '-qm', 'test: stage generated source')
        self.env['RELEASE_TEST_HEAD'] = self.git_run('rev-parse', 'HEAD').stdout.strip()
        notes = (self.project / 'CHANGELOG.md').read_bytes()
        result = self.release('--yes')
        self.assertEqual(1, result.returncode, result.stdout + result.stderr)
        self.assertEqual(notes, (self.project / 'CHANGELOG.md').read_bytes())
        self.assertNotIn('v1.1.0', self.git_run('tag').stdout)
        self.assertNotIn('push', self.calls.read_text())

    def test_failed_validation_does_not_release(self):
        test = self.project / 'bin/test'
        test.write_text('#!/bin/bash\nexit 1\n')
        self.git_run('add', 'bin/test')
        self.git_run('commit', '-qm', 'test: fail checks')
        self.env['RELEASE_TEST_HEAD'] = self.git_run('rev-parse', 'HEAD').stdout.strip()
        notes = (self.project / 'CHANGELOG.md').read_bytes()
        result = self.release('--yes')
        self.assertEqual(1, result.returncode)
        self.assertEqual(notes, (self.project / 'CHANGELOG.md').read_bytes())
        self.assertEqual(self.env['RELEASE_TEST_HEAD'], self.git_run('rev-parse', 'HEAD').stdout.strip())
        self.assertNotIn('v1.1.0', self.git_run('tag').stdout)
        self.assertNotIn('push', self.calls.read_text())

    def test_preconditions_refuse_before_mutation(self):
        for change in ('branch', 'dirty', 'sync', 'auth', 'empty'):
            with self.subTest(change=change):
                original = (self.project / 'CHANGELOG.md').read_text()
                if change == 'branch': self.git_run('checkout', '-qb', 'other')
                if change == 'dirty': (self.project / 'untracked').touch()
                if change == 'sync': self.env['RELEASE_TEST_HEAD'] = '0' * 40
                if change == 'auth': self.env['RELEASE_AUTH_STATUS'] = '1'
                if change == 'empty':
                    (self.project / 'CHANGELOG.md').write_text('## [Unreleased]\n\n')
                    self.git_run('add', 'CHANGELOG.md')
                    self.git_run('commit', '-qm', 'docs: empty')
                    self.env['RELEASE_TEST_HEAD'] = self.git_run('rev-parse', 'HEAD').stdout.strip()
                result = self.release('--yes')
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                self.assertNotIn('v1.1.0', self.git_run('tag').stdout)
                if change == 'branch': self.git_run('checkout', '-q', 'main')
                if change == 'dirty': (self.project / 'untracked').unlink()
                self.env['RELEASE_TEST_HEAD'] = self.head
                self.env['RELEASE_AUTH_STATUS'] = '0'
                if change == 'empty':
                    self.git_run('reset', '--hard', self.head)
                    self.assertEqual(original, (self.project / 'CHANGELOG.md').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
