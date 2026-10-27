#!/usr/bin/env python3
"""Self-tests of the doctest runner.

They pin the behavior of scripts/docs-test/run.py against a fixture tree: the
agreement between the plan and the documentation, the execution of the scripts
and the transcripts, and the failures that have to break the gate.

Run them with 'python scripts/docs-test/test_run.py'.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The self-test imports the runner: it does not leave its bytecode behind.
sys.dont_write_bytecode = True

RUNNER = Path(__file__).with_name("run.py")
REPO_ROOT = Path(__file__).resolve().parents[2]


def load_runner():
    """Loads the runner as a module."""
    spec = importlib.util.spec_from_file_location("docs_test_run", RUNNER)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


RUN = load_runner()


class GateTest(unittest.TestCase):
    """The gate of the runner against a fixture tree."""

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.root = Path(self.directory.name)
        self.addCleanup(self.directory.cleanup)
        self.original_root = RUN.REPO_ROOT
        RUN.REPO_ROOT = self.root
        self.addCleanup(setattr, RUN, "REPO_ROOT", self.original_root)

    def fixture(self, blocks: list[tuple[str, str]], declarations: list[str]) -> Path:
        """Writes a fixture document and the plan that declares its blocks."""
        document = "# Fixture\n\n"
        for language, body in blocks:
            document += f"```{language}\n{body}\n```\n\n"
        (self.root / "README.md").write_text(document, encoding="utf-8")
        plan = self.root / "scripts" / "docs-test" / "plan.toml"
        plan.parent.mkdir(parents=True, exist_ok=True)
        plan.write_text(
            '[plan]\nversion = 1\ndocuments = ["README.md"]\n\n'
            + "\n".join(declarations)
            + "\n",
            encoding="utf-8",
        )
        return plan

    @staticmethod
    def declaration(
        mode: str = "task",
        language: str = "bash",
        kind: str = "script",
        index: int = 1,
    ) -> str:
        """Returns a declaration of the plan."""
        return (
            "[[block]]\n"
            'file = "README.md"\n'
            f"index = {index}\n"
            f'language = "{language}"\n'
            f'kind = "{kind}"\n'
            f'mode = "{mode}"\n'
            'reason = "the reason"\n'
        )

    def gate(self, plan: Path, timeout: int = 30) -> tuple[int, str]:
        """Runs the gate and returns its exit code and its output."""
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = RUN.main(["--plan", str(plan), "--timeout", str(timeout)])
        return code, output.getvalue()

    def test_a_script_task_runs(self):
        plan = self.fixture([("bash", "echo hello")], [self.declaration()])
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_a_broken_script_fails(self):
        plan = self.fixture([("bash", "exit 3")], [self.declaration()])
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)

    def test_a_skipped_block_is_not_executed(self):
        plan = self.fixture([("bash", "exit 3")], [self.declaration("skip")])
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_a_transcript_with_its_evidence_passes(self):
        plan = self.fixture(
            [("text", "$ echo hello\nhello")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_a_transcript_without_its_evidence_fails(self):
        plan = self.fixture(
            [("text", "$ echo hello\ngoodbye")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)

    def test_a_transcript_may_print_more_than_it_documents(self):
        plan = self.fixture(
            [("text", "$ printf 'hello\\nextra\\n'\nhello")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_an_annotation_documents_the_absence_of_output(self):
        plan = self.fixture(
            [("text", "$ grep -q zzz README.md\n# empty: no match")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_a_line_that_starts_with_a_hash_is_evidence(self):
        plan = self.fixture(
            [("text", "$ printf '# not a comment\\n'\n# not a comment")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_a_missing_line_that_starts_with_a_hash_fails(self):
        plan = self.fixture(
            [("text", "$ printf 'hello\\n'\n# not a comment")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)

    def test_a_script_stays_a_script_when_it_holds_a_prompt(self):
        plan = self.fixture(
            [("bash", "cat <<'EOF'\n$ not a prompt\nEOF")],
            [self.declaration()],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_an_undeclared_block_fails(self):
        plan = self.fixture([("bash", "echo hello")], [])
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)
        self.assertIn("is not declared in the plan", output)

    def test_a_declaration_without_a_block_fails(self):
        plan = self.fixture([], [self.declaration()])
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)
        self.assertIn("does not have", output)

    def test_a_changed_language_fails(self):
        plan = self.fixture([("sh", "echo hello")], [self.declaration("task", "bash")])
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)

    def test_a_changed_kind_fails(self):
        plan = self.fixture(
            [("text", "$ echo hello\nhello")],
            [self.declaration("task", "text", "script")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)

    def test_a_declaration_without_a_reason_fails(self):
        declaration = self.declaration().replace('reason = "the reason"\n', "")
        plan = self.fixture([("bash", "echo hello")], [declaration])
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)
        self.assertIn("reason", output)

    def test_an_empty_reason_fails(self):
        declaration = self.declaration().replace('reason = "the reason"', 'reason = ""')
        plan = self.fixture([("bash", "echo hello")], [declaration])
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)
        self.assertIn("has no reason", output)

    def test_a_failing_transcript_reports_the_error_output(self):
        plan = self.fixture(
            [("text", "$ sh -c 'echo boom >&2; exit 1'")],
            [self.declaration("task", "text", "transcript")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)
        self.assertIn("boom", output)

    def test_a_powershell_task_is_refused(self):
        plan = self.fixture(
            [("powershell", "Get-FileHash vaulta.exe")],
            [self.declaration("task", "powershell", "powershell")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 1, output)
        self.assertIn("cannot execute", output)

    def test_an_unlabeled_sql_block_is_a_sql_block(self):
        plan = self.fixture(
            [("", "PRAGMA journal_mode = WAL;")],
            [self.declaration("skip", "", "sql")],
        )
        code, output = self.gate(plan)
        self.assertEqual(code, 0, output)

    def test_a_timeout_fails_and_leaves_no_orphan(self):
        plan = self.fixture([("bash", "sleep 987")], [self.declaration()])
        code, output = self.gate(plan, timeout=1)
        self.assertEqual(code, 1, output)
        if shutil.which("pgrep") is None:
            self.skipTest("pgrep is not available")
        orphans = subprocess.run(
            ["pgrep", "-f", "sleep 987"], capture_output=True, text=True, check=False
        )
        self.assertNotEqual(orphans.returncode, 0, orphans.stdout)


if __name__ == "__main__":
    unittest.main()
