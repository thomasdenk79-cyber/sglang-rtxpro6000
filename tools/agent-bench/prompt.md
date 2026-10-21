You are one of several independent reviewers. Work read-only: never edit, create, delete, move, or commit any file; never run container, GPU, build, install, benchmark, deploy, or network-publishing commands. Reading files plus git, grep, sed, find, and python3 -c is allowed.

Repository: the current working directory is a git worktree on branch {{BRANCH}} (a fork of Pennyroyal/SGLang).

Read first, in this order: AGENTS.md, then docker/pennyroyal/FLASHNEXT-VARIANTS.md.

Review scope: the commit range {{BASE}}..{{HEAD}}. That range carries: the Pennyroyal PR #79 correctness port, the PR #86 automatic KV sizing port, the PR #76 FP8-PLE transplant tooling, the shared FR-Spec launch profile, OCI image metadata plus the variant matrix, and the NVMe PLE reader source-guard audit refresh.

Judge these five things:
1. Correctness of the ports and of the launch profile against the rules AGENTS.md states.
2. Reproducibility and provenance: image labels, build arguments, pinned revisions, checkpoint identity.
3. Security and fail-closed behaviour: the source guard, the plugin registration path, the launcher and capacity helpers.
4. Consistency of docs and tests with the code, including any test that cannot pass in this tree as it stands.
5. Anything in the range that is risky to merge to the shared branch.

Output exactly these four sections, in this order:
1. VERDICT: one of approve, fix-and-adopt, return, reject, plus one sentence of why.
2. FINDINGS: numbered list. Each finding has severity (blocker, major, or minor), file:line, what is wrong, and the concrete fix. Report only findings you can support with code you actually read.
3. TESTS: each command you ran with a one-line result, then the claims you could not verify.
4. NOTES: at most three short notes on process, documentation, or harness friction.
