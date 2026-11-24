**Functional validation on `c4d77f7`**, using real Kind/kcp APIs and three workspaces.
Provider writes were simulated; each configuration used a fresh agent.

- Default mode: **9/9 scenarios + 9/9 admission checks passed**, covering all four directions,
  legacy booleans, disabled status, watches, and primary cleanup.
- Fresh E2E: **five status scenarios + CRD validation passed** (`-count=1`).
- SSA: reverse directions pass on this PR; **all four pass** when combined locally with `f0db0c6`.

[Method and scripts][method] · [JSON results][results] · [E2E output][e2e] · [Agent logs][logs].

Separate follow-up: hot reconfiguration left old controllers active and a retained finalizer.
The [detailed report][details] also records the manual kcp owner linkage and HTTP probe 404s.

<!-- Evidence links are replaced by render_comment.py when preparing an MR comment. -->

[method]: README.md
[results]: summary.json
[e2e]: logs/e2e.log
[logs]: logs/
[details]: REPORT.md
