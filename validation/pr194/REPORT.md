## Detailed functional validation

I revalidated [c4d77f7][head] on 2026-11-24 using the local demo and a fresh focused E2E run.
The operator's steady-state synchronization paths and the released boolean configuration work in
the tested scenarios. The SSA dependency and the additional findings below remain relevant.

See the [evidence index](README.md) for reproduction scripts and all published outputs.

### Environment and scope

- A dedicated Kind cluster, Kubernetes `v1.37.0`, and kcp `v0.32.0`.
- Three kcp workspaces: `application-provider`, `database-provider`, and `customer`.
- Real APIExports, APIExportEndpointSlices, APIBindings, accepted permission claims, and provider
  virtual-workspace clients.
- An `api-syncagent` binary rebuilt from the PR's Go sources and CRDs at `c4d77f7`, running locally.
- Provider reconciliation was simulated with explicit API writes. This validates synchronization;
  it does not provision a real database or test a production provider deployment.

Each matrix configuration was installed before starting a fresh agent. Hot reconfiguration was
tested separately and is discussed below.

### Status origin matrix

Every row uses `syncStatus: true`. Spec follows `origin`; status follows `syncStatusOrigin`.

| origin | syncStatusOrigin | Default mode | SSA: PR alone | SSA: with fix |
|---|---|---|---|---|
| kcp | kcp | PASS | Needs SSA fix | PASS |
| kcp | service | PASS | PASS | PASS |
| service | service | PASS | Needs SSA fix | PASS |
| service | kcp | PASS | PASS | PASS |

"Default mode" means `--enable-server-side-apply=false`. For the last column, I built a local
combination of `c4d77f7` and the separate [SSA fix f0db0c6][ssa].
The feature PR branch was left unchanged. This branch only adds test evidence.

Recorded assertions: [default mode](results/client.json), [standalone SSA](results/ssa.json), and
[combined build](results/combined.json). Corresponding agent output is in [logs](logs/).

With SSA on the PR alone, status forwarding in the same direction as spec remained absent even
after explicitly triggering primary reconciliation. The local combination with the SSA fix passed
all four configurations. These two SSA-only failures are recorded separately from passing results.

For all four default-mode configurations I checked:

- Initial related-resource spec placement and a subsequent `storageGiB: 20 → 31` update.
- Propagation of both `status.phase` and `status.endpoint` from the configured status origin.
- Related-only status updates, without manually modifying the primary to trigger reconciliation.
  The primary's `resourceVersion` stayed unchanged during these checks.
- Continued spec synchronization after status synchronization.
- Primary spec forwarding, primary status back-sync, and primary deletion/finalizer cleanup.
  Remaining related test objects were explicitly cleaned up afterwards.

### Compatibility and watch behavior

| Configuration | Observation | Result |
|---|---|---|
| `origin: kcp`, `syncStatus: true`, no new field | Status follows spec | PASS |
| `origin: service`, `syncStatus: true`, no new field | Status follows spec | PASS |
| `syncStatus: false` | Status stays absent after primary reconciliation | PASS |
| `syncStatus` omitted | Status stays absent after primary reconciliation | PASS |
| kcp origin/status, `watch` omitted | Status waits for a primary event | PASS |

Spec updates continued to synchronize with status disabled or omitted. For the no-watch case, a
status-only update did not propagate during a 10-second observation window; it propagated after an
explicit primary annotation triggered reconciliation. This confirms the documented limitation.

Nine server-side admission checks also passed: existing boolean configurations are accepted, while
invalid origins, missing/disabled `syncStatus` with an explicit status origin, a missing required
watch, `watch: {}`, and the old string form `syncStatus: kcp` are rejected.

The [admission diagnostics](results/admission.json) include the expected rejection messages.

### Full demo use case with `byOwner`

The service-origin, kcp-status scenario passed with SSA enabled:

```yaml
origin: service
syncStatus: true
syncStatusOrigin: kcp
watch:
  byOwner: {}
```

The customer Application reached the service cluster, its status returned to the customer, the
Database spec reached kcp, and Database status returned through the Database provider's virtual
workspace. Subsequent spec and status updates also propagated. Both Database copies reported:

```yaml
spec:
  storageGiB: 31
status:
  phase: ReadyAgain
  endpoint: updated.demo.svc:5432
```

The generated kcp copy initially had no owner reference. I explicitly added its kcp-local
Application owner before testing the kcp-side `byOwner` watch. The owner UIDs were different on
the two clusters and matched the primary on their own side. Automatic cross-cluster ownership
linking is therefore not claimed by this test.

See the [scenario output](logs/by-owner-steps.log), [agent log](logs/by-owner.log), and
[recorded assertions](results/by-owner.json).

### Fresh repository E2E run

The following focused run passed with caching disabled:

```bash
status_tests='TestValidateRelatedResourceSpec|TestSyncRelatedObjectStatus'
GOTOOLCHAIN=go1.26.10 \
TEST_ARGS="-timeout 10m -v -count=1 -run $status_tests" \
  make clean build test-e2e
```

Passing status scenarios:

```text
TestSyncRelatedObjectStatusFromKcp
TestSyncRelatedObjectStatusBackToKcp
TestSyncRelatedObjectStatusFromService
TestSyncRelatedObjectStatusFromKcpWithServiceOrigin
TestSyncRelatedObjectStatusNotSyncedByDefault
```

`TestValidateRelatedResourceSpec` also passed. The tracked E2E scenarios additionally cover a
projection that changes the related resource Kind, including workspace-specific watch resolution.

The complete captured [E2E output](logs/e2e.log) is included in this archive.

### Additional findings requiring follow-up

- Updating the same PublishedResource in place left previous sync controllers active. After
  changing origin, a kcp test copy retained a cleanup finalizer after its primary was deleted.
  The sync-manager code responsible is unchanged from `main`. I preserved that failed run and
  restarted the agent between configurations for the passing steady-state matrix above. Reliable
  hot reconfiguration is not established by these results.
  See the [failed run](results/hot-reload.json), [agent output](logs/hot-reload.log), and
  [orphaned object's metadata](results/orphan.json).
- With the health listener enabled, `/readyz` and `/healthz` returned HTTP 404. Functional readiness
  was checked through API publication, APIBinding readiness, and actual reconciliation instead.
  This manual observation is recorded in [the summary](summary.json).
  An HTTP transcript was not kept.

[head]: https://github.com/arfevrier/api-syncagent/commit/c4d77f7f44b8f44fac5fd1ce864b19a787b8aa82
[ssa]: https://github.com/arfevrier/api-syncagent/commit/f0db0c614531ecd6797dabe7292b144775d3df2f
