# PR #194: functional validation evidence

This branch archives the validation of feature commit `c4d77f7` on 2026-11-24.
It adds the local demo harness and recorded evidence; the feature PR branch is unchanged.

The operator ran against a dedicated Kind cluster (`v1.37.0`) and kcp (`v0.32.0`), with provider
and customer workspaces, APIExports, APIBindings, permission claims, and virtual workspaces.
Provider reconciliation was simulated with explicit API writes.

## Start here

- [Summary and provenance](summary.json)
- [Detailed observations and limitations](REPORT.md)
- [Demo setup and reproduction instructions](../../demo/README.md)
- [Functional test runner](../../demo/validate-status-origins.py)
- [Short MR comment template](COMMENT.template.md)

Each passing matrix configuration was installed before starting a fresh agent. An additional
in-place reconfiguration run failed; it is retained separately below.

## Results and output

| Check | Result | Recorded assertions |
|---|---|---|
| Default synchronization mode | 9 PASS | [JSON](results/client.json) |
| Server-side admission | 9 PASS, including rejection reasons | [JSON](results/admission.json) |
| `byOwner` demo with SSA | PASS, manual kcp-local owner | [JSON](results/by-owner.json) |
| SSA, feature alone | 2 PASS, 2 require the SSA fix | [JSON](results/ssa.json) |
| SSA, local combination with `f0db0c6` | 4 PASS | [JSON](results/combined.json) |
| In-place reconfiguration | Failed cleanup | [JSON](results/hot-reload.json) |

Output captured during the runs:

- [Fresh repository E2E output](logs/e2e.log): five status scenarios and CRD validation passed.
- [Infrastructure setup](logs/init.log) and [feature binary build](logs/build.log).
- [`byOwner` scenario output](logs/by-owner-steps.log) and [agent log](logs/by-owner.log).
- [Default-mode agent logs](logs/), named `client-<scenario>.log`.
- [Standalone SSA agent logs](logs/), named `ssa-<scenario>.log`.
- [Combined-build agent logs](logs/), named `combined-<scenario>.log`.
- [Combined binary build output](logs/combined-build.log).
- [Failed hot-reconfiguration agent log](logs/hot-reload.log) and
  [orphaned test object's metadata](results/orphan.json).

The JSON matrices record the assertions from the harness. They are not reconstructed console logs.
The `.log` files contain captured process output, with publication-only normalization below.

## Source revisions and scope

- Feature: `c4d77f7f44b8f44fac5fd1ce864b19a787b8aa82`.
- Local SSA integration: feature plus `f0db0c614531ecd6797dabe7292b144775d3df2f`.
- The integration fix was applied in a temporary worktree, without adding it to the feature branch.
- The dedicated Kind cluster and kcp process were stopped after validation.
- `/readyz` and `/healthz` returning 404 were manual observations recorded in the summary.
  An original HTTP transcript was not retained. Functional readiness used API publication,
  APIBinding readiness, and observed reconciliation.
- No external database was provisioned, and production deployment/RBAC was not validated.

The in-place reconfiguration finding is distinct from the passing fixed-configuration matrix.
The responsible sync-manager source is unchanged from the feature's `main` base. The failed run
left a cleanup finalizer on a test copy; that test object required manual cleanup.

## Publication handling

Workstation paths, private IPv4 addresses, and unrelated local context names were replaced.
ANSI sequences and trailing display whitespace were removed where present.
The logs retain their timestamps, verdicts, controller activity, and test payloads.
[The manifest](manifest.json) records original and published SHA-256 hashes and replacement counts.

The archive excludes kubeconfigs, certificates, keys, binaries, PID files, machine-specific
environment settings, and the raw kcp server log/state. Only explicitly selected text artifacts
are included. Original artifacts remain local.

## Reproduce

Checkout this branch and follow [the demo README](../../demo/README.md) to create a dedicated
environment. The application Go sources and CRDs are identical to the tested feature revision.

After setup and compilation:

```bash
python3 demo/validate-status-origins.py --scenario by-owner --ssa --label by-owner
python3 demo/validate-status-origins.py --label client-side
python3 demo/validate-status-origins.py --ssa \
  --cases kcp-kcp,kcp-service,service-service,service-kcp \
  --allow-known-ssa-forward-issue --label ssa-standalone
```

`KNOWN_ISSUE` is kept distinct from `PASS`. For the combined-build check:

```bash
git worktree add --detach ../pr194-combined c4d77f7
git -C ../pr194-combined cherry-pick --no-commit f0db0c6
make -C ../pr194-combined -B api-syncagent \
  BUILD_DEST="$DEMO_STATE_DIR/bin-with-ssa-fix"
python3 demo/validate-status-origins.py --ssa \
  --binary "$DEMO_STATE_DIR/bin-with-ssa-fix/api-syncagent" \
  --cases kcp-kcp,kcp-service,service-service,service-kcp --label combined
```

The tracked repository E2E command and the separate follow-up findings are in
[the detailed report](REPORT.md).

## Prepare the short MR comment

This command renders links pinned to the unique 12-character prefix of the evidence commit,
rather than to a branch that can move:

```bash
python3 validation/pr194/render_comment.py "$(git rev-parse HEAD)" \
  --output /tmp/pr194-comment.md
```
