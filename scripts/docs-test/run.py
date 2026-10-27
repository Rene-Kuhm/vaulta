#!/usr/bin/env python3
"""Runs the executable examples of the documentation as doctests.

Every executable block of README.md and docs/ is declared in
`scripts/docs-test/plan.toml` as one of:

* `task`: the runner executes the block and fails when the example breaks.
* `skip`: the runner does not execute the block; the plan records why.

The runner also fails when the documentation drifts away from the plan: a
block that is not declared, a declaration without a block and a block whose
language or kind changed all break the gate. That keeps the plan an accurate
map of the executable examples instead of a list that silently rots.

What a task has to prove:

* a script has to run and exit with 0;
* a transcript has to print the evidence the page documents. The comparison is
  one sided: every documented line has to be printed, but the command may print
  more. The pages of the repository record the snapshot they were checked at,
  so an output that grew does not make the documented evidence wrong.

A SQL block and a PowerShell script are executable, but not with this runner:
they need a live database and Windows, so the plan declares them as a `skip`.

The runner uses the standard library only, never reaches the network and runs
the examples in the repository root, so it runs in the hermetic CI checkout
(`mise run docs-test`).

Usage:
    python scripts/docs-test/run.py            # run the plan
    python scripts/docs-test/run.py --list     # list the executable blocks
"""
from __future__ import annotations

import argparse
import os
import re
import signal
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

# Resolved from this file's location so the script works in any clone.
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PLAN = REPO_ROOT / "scripts" / "docs-test" / "plan.toml"

# The languages the runner executes as a script.
SHELL_LANGUAGES = frozenset({"bash", "sh", "shell", "zsh"})
# A console block holds a session: it is a transcript when it has prompts.
CONSOLE_LANGUAGES = frozenset({"console"})
# PowerShell runs on Windows: the runner declares those blocks and never
# executes them.
POWERSHELL_LANGUAGES = frozenset({"powershell", "pwsh"})
# SQL is executable, but only against a live database, so it is never a task.
SQL_LANGUAGES = frozenset({"sql"})
# An unlabeled fence that opens with a statement is SQL.
SQL_STATEMENT = re.compile(
    r"^(pragma|select|insert|update|delete|create|alter|drop|with|grant|revoke"
    r"|begin|commit|vacuum|explain)\b",
    re.IGNORECASE,
)

# A line that starts with "$ " is a shell prompt: the block is a transcript of
# commands and their output, not a script.
PROMPT = re.compile(r"^\$ (?=\S)")
# `path:12:` is the line number grep prints; it moves with every edit, so it is
# dropped before the output of a transcript is compared.
LINE_NUMBER = re.compile(r"^(?P<path>[^\s:]+):(?P<number>\d+):")
WHITESPACE = re.compile(r"\s+")
FENCE = re.compile(r"^(?P<indent>[ \t]*)(?P<marker>`{3,}|~{3,})(?P<info>.*)$")
# `grep` exits with 1 when it finds nothing: that is the documented "no match".
GREP_LIKE = re.compile(r"^(e|f|grep|rg)\b")
# A transcript annotates the absence of output with a comment: "# empty: ...".
ANNOTATION = re.compile(r"^#\s*(empty|no output|nothing)\b", re.IGNORECASE)

# The examples never reach the network: the proxies of the child processes
# point at a closed port, so a tool that honours them fails instead of
# downloading something.
OFFLINE_ENVIRONMENT = {
    "http_proxy": "http://127.0.0.1:9",
    "https_proxy": "http://127.0.0.1:9",
    "all_proxy": "http://127.0.0.1:9",
    "ftp_proxy": "http://127.0.0.1:9",
    "no_proxy": "",
    "HTTP_PROXY": "http://127.0.0.1:9",
    "HTTPS_PROXY": "http://127.0.0.1:9",
    "ALL_PROXY": "http://127.0.0.1:9",
    "FTP_PROXY": "http://127.0.0.1:9",
    "NO_PROXY": "",
    "GIT_TERMINAL_PROMPT": "0",
    "PIP_NO_INPUT": "1",
}

DEFAULT_TIMEOUT = 120


@dataclass(frozen=True)
class Block:
    """An executable block of a document."""

    file: str
    index: int
    language: str
    kind: str
    body: str
    line: int

    @property
    def label(self) -> str:
        """Returns the identifier used by the plan and by the report."""
        return f"{self.file} block {self.index}"

    @property
    def key(self) -> tuple[str, int]:
        """Returns the key that binds a block to a declaration."""
        return (self.file, self.index)


@dataclass(frozen=True)
class Entry:
    """A declaration of the plan."""

    file: str
    index: int
    language: str
    kind: str
    mode: str
    reason: str

    @property
    def key(self) -> tuple[str, int]:
        """Returns the key that binds a declaration to a block."""
        return (self.file, self.index)


@dataclass(frozen=True)
class Command:
    """One command of a shell transcript."""

    text: str
    expected: tuple[str, ...]


def relative(path: Path) -> str:
    """Returns the repository-relative path of a file."""
    return path.resolve().relative_to(REPO_ROOT).as_posix()


def documents_of(entries: list[str]) -> list[Path]:
    """Returns the Markdown files of the documentation scope, sorted."""
    paths: list[Path] = []
    for entry in entries:
        target = REPO_ROOT / entry
        if target.is_dir():
            paths.extend(sorted(target.rglob("*.md")))
        elif target.is_file():
            paths.append(target)
        else:
            raise SystemExit(f"docs-test: '{entry}' is not a document of the repository")
    return sorted(set(paths))


def classify(body: str, language: str) -> str | None:
    """Returns the kind of an executable block, or None when it is data.

    The language of the fence decides first: a `bash` block is a script even
    when its body holds a line that starts with "$ ". Only the blocks that
    document a session (`console`, `text` or an unlabeled fence) become a
    transcript, and only when they hold prompts.
    """
    if language in SHELL_LANGUAGES:
        return "script"
    if language in POWERSHELL_LANGUAGES:
        return "powershell"
    if language in SQL_LANGUAGES:
        return "sql"
    has_prompt = any(PROMPT.match(line) for line in body.splitlines())
    if language in CONSOLE_LANGUAGES:
        return "transcript" if has_prompt else "script"
    if has_prompt:
        return "transcript"
    if not language:
        first = next((line.strip() for line in body.splitlines() if line.strip()), "")
        if SQL_STATEMENT.match(first):
            return "sql"
    return None


def extract_blocks(path: Path) -> list[Block]:
    """Returns the executable blocks of a Markdown file, in document order."""
    lines = path.read_text(encoding="utf-8").splitlines()
    blocks: list[Block] = []
    index = 0
    position = 0
    while position < len(lines):
        opening = FENCE.match(lines[position])
        if opening is None:
            position += 1
            continue
        marker = opening.group("marker")
        info = opening.group("info").strip()
        body: list[str] = []
        start = position
        position += 1
        closed = False
        while position < len(lines):
            closing = FENCE.match(lines[position])
            if (
                closing is not None
                and closing.group("marker")[0] == marker[0]
                and len(closing.group("marker")) >= len(marker)
            ):
                position += 1
                closed = True
                break
            body.append(lines[position])
            position += 1
        if not closed:
            # An unterminated fence is not a block.
            continue
        language = info.split()[0].lower() if info else ""
        kind = classify("\n".join(body), language)
        if kind is None:
            continue
        index += 1
        blocks.append(
            Block(
                file=relative(path),
                index=index,
                language=language,
                kind=kind,
                body="\n".join(body),
                line=start + 1,
            )
        )
    return blocks


def collect_blocks(documents: list[str]) -> list[Block]:
    """Returns every executable block of the documentation scope."""
    blocks: list[Block] = []
    for path in documents_of(documents):
        blocks.extend(extract_blocks(path))
    return blocks


def load_plan(path: Path) -> tuple[list[Entry], list[str], list[str]]:
    """Returns the declarations, the documentation scope and the problems."""
    problems: list[str] = []
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise SystemExit(f"docs-test: cannot read the plan '{path}': {error}")

    documents = data.get("plan", {}).get("documents", ["README.md", "docs"])
    if not isinstance(documents, list) or not all(
        isinstance(item, str) for item in documents
    ):
        problems.append("plan.documents has to be a list of paths")
        documents = ["README.md", "docs"]

    raw_blocks = data.get("block", [])
    if not isinstance(raw_blocks, list):
        problems.append("the plan has to declare its blocks with [[block]] tables")
        raw_blocks = []

    entries: list[Entry] = []
    for position, raw in enumerate(raw_blocks, start=1):
        if not isinstance(raw, dict):
            problems.append(f"block {position} of the plan is not a table")
            continue
        required = ("file", "index", "language", "kind", "mode", "reason")
        missing = [key for key in required if key not in raw]
        if missing:
            problems.append(
                f"block {position} of the plan is missing {', '.join(missing)}"
            )
            continue
        file = raw["file"]
        index = raw["index"]
        language = raw["language"]
        kind = raw["kind"]
        mode = raw["mode"]
        reason = raw["reason"]
        if not isinstance(file, str) or not file:
            problems.append(f"block {position} of the plan has an invalid 'file'")
            continue
        if not isinstance(index, int) or isinstance(index, bool) or index < 1:
            problems.append(f"block {position} of the plan has an invalid 'index'")
            continue
        if not isinstance(language, str):
            problems.append(f"block {position} of the plan has an invalid 'language'")
            continue
        if not isinstance(kind, str) or not kind:
            problems.append(f"block {position} of the plan has an invalid 'kind'")
            continue
        if mode not in ("task", "skip"):
            problems.append(
                f"block {position} of the plan has the invalid mode '{mode}' "
                "(it has to be 'task' or 'skip')"
            )
            continue
        if not isinstance(reason, str) or not reason.strip():
            problems.append(
                f"block {position} of the plan ({file} block {index}) has no reason"
            )
            continue
        entries.append(
            Entry(
                file=file,
                index=index,
                language=language.lower(),
                kind=kind.lower(),
                mode=mode,
                reason=reason.strip(),
            )
        )
    return entries, documents, problems


def unclosed_quote(text: str) -> bool:
    """Returns whether a command ends inside a quoted string."""
    single = False
    double = False
    escaped = False
    for character in text:
        if escaped:
            escaped = False
            continue
        if character == "\\":
            escaped = True
            continue
        if character == "'" and not double:
            single = not single
        elif character == '"' and not single:
            double = not double
    return single or double


def join_continuation(text: str, following: str) -> str:
    """Returns a command continued on the next line."""
    if text.endswith("\\"):
        return f"{text[:-1].rstrip()} {following.strip()}"
    return f"{text}\n{following}"


def parse_transcript(body: str) -> list[Command]:
    """Returns the commands of a shell transcript, with their output.

    A command is a line that starts with "$ "; the lines that follow it, up
    to the next command, are the output the transcript documents. A command
    that ends with a backslash, or that leaves a quote open, continues on the
    next line.
    """
    commands: list[Command] = []
    lines = body.splitlines()
    position = 0
    while position < len(lines):
        line = lines[position]
        if not PROMPT.match(line):
            position += 1
            continue
        text = line[2:].strip()
        position += 1
        while position < len(lines) and (
            text.endswith("\\") or unclosed_quote(text)
        ):
            text = join_continuation(text, lines[position])
            position += 1
        text = text.removesuffix("\\").rstrip()
        expected: list[str] = []
        while position < len(lines) and not PROMPT.match(lines[position]):
            expected.append(lines[position])
            position += 1
        commands.append(Command(text=text, expected=tuple(expected)))
    return commands


def normalize(line: str) -> str:
    """Returns a comparable form of a line of output."""
    line = LINE_NUMBER.sub(lambda match: f"{match.group('path')}:", line.rstrip())
    return WHITESPACE.sub(" ", line).strip()


def expectations(lines: tuple[str, ...]) -> tuple[list[str], bool]:
    """Returns the evidence a transcript documents and whether it expects none.

    A section that only holds annotations (`# empty: ...`) documents the
    absence of output. Every other line is evidence that the command has to
    print, a line that starts with "#" included.
    """
    entries = [line.strip() for line in lines if line.strip()]
    evidence = [normalize(line) for line in entries if not ANNOTATION.match(line)]
    if not evidence:
        return [], bool(entries)
    return evidence, False


def child_environment() -> dict[str, str]:
    """Returns the environment of an example: the tools of the machine and no
    route to the network."""
    environment = dict(os.environ)
    environment.update(OFFLINE_ENVIRONMENT)
    return environment


def run(command: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    """Runs a command in the repository root and captures its output.

    The command runs in its own process group, so a timeout kills the whole
    tree and leaves no orphan behind.
    """
    process = subprocess.Popen(
        command,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=child_environment(),
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def check_script(block: Block, timeout: int) -> list[str]:
    """Executes a script block and returns its failures."""
    try:
        result = run(["bash", "-euo", "pipefail", "-c", block.body], timeout)
    except subprocess.TimeoutExpired:
        return [f"the script timed out after {timeout}s"]
    if result.returncode != 0:
        return [
            f"the script exited with {result.returncode}",
            f"stdout: {result.stdout.strip() or '<empty>'}",
            f"stderr: {result.stderr.strip() or '<empty>'}",
        ]
    return []


def with_stderr(message: str, result: subprocess.CompletedProcess[str]) -> str:
    """Returns a failure message with the error output of the command."""
    detail = result.stderr.strip()
    return f"{message}: {detail}" if detail else message


def check_transcript(block: Block, timeout: int) -> list[str]:
    """Executes a transcript block and returns its failures."""
    failures: list[str] = []
    for command in parse_transcript(block.body):
        try:
            result = run(["bash", "-c", command.text], timeout)
        except subprocess.TimeoutExpired:
            failures.append(f"`{command.text}` timed out after {timeout}s")
            continue
        expected, expects_none = expectations(command.expected)
        actual = [normalize(line) for line in result.stdout.splitlines()]
        if expected:
            if result.returncode != 0:
                failures.append(
                    with_stderr(
                        f"`{command.text}` exited with {result.returncode}", result
                    )
                )
                continue
            missing = [line for line in expected if line not in actual]
            if missing:
                failures.append(
                    with_stderr(
                        f"`{command.text}` does not print {', '.join(missing)}", result
                    )
                )
            continue
        if expects_none:
            if any(actual):
                failures.append(
                    with_stderr(
                        f"`{command.text}` prints output, the transcript expects none",
                        result,
                    )
                )
                continue
            # `grep` exits with 1 when it finds nothing, which is the documented
            # result of the "no match" commands.
            tolerated = result.returncode == 1 and GREP_LIKE.match(command.text)
            if result.returncode != 0 and not tolerated:
                failures.append(
                    with_stderr(
                        f"`{command.text}` exited with {result.returncode}", result
                    )
                )
            continue
        if result.returncode != 0:
            failures.append(
                with_stderr(f"`{command.text}` exited with {result.returncode}", result)
            )
    return failures


def check_block(block: Block, timeout: int) -> list[str]:
    """Executes an executable block and returns its failures."""
    if block.kind == "script":
        return check_script(block, timeout)
    if block.kind == "transcript":
        return check_transcript(block, timeout)
    return [f"the runner cannot execute a '{block.kind}' block"]


def main(argv: list[str]) -> int:
    """Runs the plan and returns the exit code of the gate."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plan",
        type=Path,
        default=DEFAULT_PLAN,
        help="the plan that declares the executable blocks",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="list the executable blocks instead of running them",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help="the seconds a single example may run",
    )
    arguments = parser.parse_args(argv)

    entries, documents, problems = load_plan(arguments.plan)
    blocks = collect_blocks(documents)

    if arguments.list:
        for block in blocks:
            print(
                f"{block.file}\t{block.index}\t{block.language}\t{block.kind}\t{block.line}"
            )
        return 0

    declared: dict[tuple[str, int], Entry] = {}
    for entry in entries:
        if entry.key in declared:
            problems.append(f"the plan declares {entry.file} block {entry.index} twice")
            continue
        declared[entry.key] = entry

    for block in blocks:
        entry = declared.get(block.key)
        if entry is None:
            problems.append(
                f"{block.file} block {block.index} ({block.language}, line "
                f"{block.line}) is not declared in the plan"
            )
            continue
        if entry.language != block.language:
            problems.append(
                f"{block.file} block {block.index} is '{block.language}' in the "
                f"documentation and '{entry.language}' in the plan"
            )
            continue
        if entry.kind != block.kind:
            problems.append(
                f"{block.file} block {block.index} is a '{block.kind}' block in the "
                f"documentation and a '{entry.kind}' block in the plan"
            )
            continue
        if entry.mode == "task" and block.kind not in ("script", "transcript"):
            problems.append(
                f"{block.file} block {block.index} is a '{block.kind}' block and "
                "the runner cannot execute it"
            )

    known = {(block.file, block.index) for block in blocks}
    for entry in entries:
        if entry.key not in known:
            problems.append(
                f"the plan declares {entry.file} block {entry.index}, which the "
                "documentation does not have"
            )

    if problems:
        print("docs-test: the plan and the documentation disagree:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    tasks = 0
    skipped = 0
    failures = 0
    for block in blocks:
        entry = declared[block.key]
        if entry.mode == "skip":
            skipped += 1
            print(f"skip  {block.label} ({block.kind}): {entry.reason}")
            continue
        tasks += 1
        problems_of_block = check_block(block, arguments.timeout)
        if problems_of_block:
            failures += 1
            print(f"FAIL  {block.label} ({block.kind}): {entry.reason}")
            for problem in problems_of_block:
                print(f"        {problem}")
        else:
            print(f"ok    {block.label} ({block.kind}): {entry.reason}")

    print(f"docs-test: {tasks} tasks passed, {skipped} skipped, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
