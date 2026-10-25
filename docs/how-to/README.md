# How-to guides

Task-oriented documentation. Each guide is a recipe for one concrete goal:
you arrive with the goal, you follow the steps, you leave with it done.

| Guide | Goal |
| --- | --- |
| [Cut a release](./release-process.md) | Publish a stable or dev build and verify what users download |
| [Sign an Android release](./android-release-signing.md) | Produce a release APK that is not signed with the debug keystore |
| [Run the release QA matrix](./release-qa-matrix.md) | Complete the checks that gate any promotion to a public build |
| [Prepare a store submission](./store-release-checklist.md) | Collect the external assets, accounts and policy answers each store needs |
| [Run a private beta](./run-a-private-beta.md) | Distribute a build to trusted testers and collect usable feedback |
| [Apply the Supabase migrations](./apply-supabase-migrations.md) | Create the schema, RPCs and RLS policies behind optional sync |

## How to read these

- Each guide starts from the state you are already in. They do not repeat the
  project overview; read the [README](../README.md) for that.
- Commands and file paths are literal. Where a guide names a secret, it names
  the environment variable rather than the value.
- The release guides overlap on purpose: a release is signing, then QA, then
  publication. Read them in that order the first time.

## Not in this folder

- Guided walkthroughs from scratch live in [`../tutorials/`](../tutorials/).
- Facts you look up live in [`../reference/`](../reference/).
- The reasoning behind these procedures lives in
  [`../explanation/`](../explanation/), and the decisions that created them in
  [`../adr/`](../adr/).
