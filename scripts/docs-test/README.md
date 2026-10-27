# Documentation doctests

`mise run docs-test` executes the examples of the documentation so a broken
example cannot be merged.

## How it works

`plan.toml` declares every executable block of `README.md` and `docs/`:

- `mode = "task"`: the runner executes the block and the gate fails when it
  breaks.
- `mode = "skip"`: the runner does not execute the block; `reason` records why
  (it needs the network, a device, a secret or a database).

The runner (`run.py`) reads the Markdown files, extracts the fenced blocks and
matches them with the plan. It fails when:

- a block of the documentation is not declared in the plan;
- the plan declares a block that the documentation does not have;
- the language or the kind of a block changed;
- a `task` block breaks.

That last point is what keeps the plan honest: a new executable example has to
be declared, and an example that stops working has to be fixed or skipped with
a reason.

## What is executable

| Kind | Fence | How it runs |
| --- | --- | --- |
| Script | `bash`, `sh`, `shell`, `zsh` | The body runs with `bash -euo pipefail` in the repository root. |
| Transcript | `console`, `text` or an unlabeled fence with `$ ` prompts | Every prompt runs on its own; the output the transcript documents has to be printed. |
| SQL | `sql`, or an unlabeled fence that opens with a statement | Always a `skip`: it needs a live database. |
| PowerShell | `powershell`, `pwsh` | Always a `skip`: it only runs on Windows. |

Data blocks (JSON, YAML, TOML, properties, Mermaid and prose) are examples, not
commands: they are not part of the plan.

The language of the fence decides first: a `bash` block is a script even when
its body holds a line that starts with `$ `.

## What a task proves

- A script has to run and exit with 0.
- A transcript has to print the evidence the page documents. The comparison is
  one sided: every documented line has to be printed, but the command may
  print more. The pages record the snapshot they were checked at, so an output
  that grew does not make the documented evidence wrong. The comparison
  ignores the line numbers `grep` prints, so an example that moved keeps
  passing.
- A transcript annotates the absence of output with a comment (`# empty: ...`).
  A line that starts with `#` and says something else is evidence.
- A command whose output the page does not document only has to exit with 0.

The examples run in the repository root, with the proxies of the child
processes pointing at a closed port: an example never reaches the network.

## Adding an example to the plan

1. Write the example in the Markdown file.
2. Run `python scripts/docs-test/run.py --list` to see the block the runner
   found. The `index` is its position among the executable blocks of the file.
3. Add the declaration to `plan.toml`:

   ```toml
   [[block]]
   file = "docs/how-to/example.md"
   index = 3
   language = "bash"
   kind = "script"
   mode = "skip"
   reason = "It launches the app on a device."
   ```

4. Run `mise run docs-test` to check the plan.

## The self-tests

`test_run.py` pins the behavior of the runner against a fixture tree: the
agreement between the plan and the documentation, the execution of the scripts
and the transcripts, and the failures that have to break the gate.

```bash
python scripts/docs-test/test_run.py
```

`mise run docs-test` runs them before the gate.
