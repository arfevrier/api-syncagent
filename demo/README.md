# `byOwner` related-resource watch demo

This local demo exercises the merge request's main use case with the complete kcp API topology.
It creates:

- one Kind service cluster;
- one local kcp server;
- `application-provider`, `database-provider`, and `customer` kcp workspaces;
- `applications` and `databases` APIExports and their APIExportEndpointSlices;
- both APIBindings in the customer workspace, including accepted permission claims;
- an `Application` primary resource and a `Database` related resource.

The Application is created by the customer in kcp and copied to Kind. The Database is owned by the
Application on each side, using the corresponding cluster-local UID. Its spec originates in Kind
and is copied to kcp. A simulated Database provider then updates `.status` through its kcp virtual
workspace.

```text
Application: customer kcp workspace  --------------------------->  Kind

Database.spec:   Kind  ----------------------------------------->  customer kcp workspace
Database.status: Kind  <-----------------------------------------  Database provider
```

The `byOwner` watch maps the service-side Database event to its local Application, so the spec is
synchronized to kcp. Owner references are cluster-local and are removed from the generated copy, so
the script first confirms that the kcp Database has no owner. It then manually adds an owner
reference using the kcp Application UID. This lets the kcp-side watch map the status event back to
the primary and synchronize the status to Kind.

## Prerequisites

The scripts prefer existing tools and the repository's downloaded kcp binary. They require Docker,
Kind, kubectl, jq, and Go. Install these tools before running the demo. If the kcp binary is
missing, `init.sh` downloads the version configured by the repository Makefile.

## Run the demo

From the repository root, initialize the infrastructure:

```bash
./demo/init.sh
```

In a second terminal, run the current branch's agent locally:

```bash
./demo/run-agent.sh
```

`run-agent.sh` rebuilds the agent from the current checkout and starts it with the following
settings:

- the Kind kubeconfig as `--kubeconfig`;
- the Application provider kubeconfig as `--kcp-kubeconfig`;
- the `applications` APIExportEndpointSlice;
- leader election disabled for a single local process;
- the default client-side synchronization mode. Set `DEMO_SERVER_SIDE_APPLY=true` to test SSA.

In a third terminal, create the bindings and resources and exercise the status flow:

```bash
./demo/load-scenario.sh
```

The last script succeeds only when the spec reaches kcp, the kcp-local owner is installed, and the
status returns to Kind.

## Inspect each view

Display the main objects from all sides:

```bash
./demo/show.sh
```

The generated kubeconfigs can also be used directly:

```bash
kubectl --kubeconfig demo/kubeconfigs/kind.kubeconfig get applications,databases -n demo
kubectl --kubeconfig demo/kubeconfigs/customer.kubeconfig get apibindings
kubectl --kubeconfig demo/kubeconfigs/customer.kubeconfig get applications,databases -A
kubectl --kubeconfig demo/kubeconfigs/database-provider-virtual-workspace.kubeconfig \
  get databases -A
```

The `demo/kubeconfigs` directory contains direct kubeconfigs for kcp root, every logical workspace,
both provider virtual workspaces scoped to the customer, and Kind.

## Functional validation

The demo uses the released boolean `syncStatus` field. `syncStatusOrigin` selects the authoritative
status side when synchronization is enabled. The supplied scenario uses `origin: service`,
`syncStatus: true`, and `syncStatusOrigin: kcp`.

The validation runner checks actual objects through the Kind and provider virtual-workspace APIs.
It starts a fresh agent for each configuration, so these checks do not claim hot reconfiguration.
Reports and agent logs are written to `DEMO_STATE_DIR`.

`validate-hot-reconfiguration.py` preserves the separate in-place-update reproduction that exposed
active old controllers and a retained finalizer. It is not part of the passing fixed-configuration
matrix; the findings are recorded in [the validation report](../validation/pr194/REPORT.md).

Use a dedicated environment so existing clusters, state, and kubeconfigs are preserved:

```bash
export DEMO_STATE_DIR="$PWD/demo/.state/validation"
export DEMO_KUBECONFIG_DIR="$PWD/demo/kubeconfigs/validation"
export DEMO_KIND_CLUSTER_NAME=api-syncagent-validation
export DEMO_KCP_PORT=17443
export DEMO_ETCD_CLIENT_PORT=12379
export DEMO_ETCD_PEER_PORT=12380
export DEMO_HEALTH_ADDRESS=127.0.0.1:18086
export DEMO_METRICS_ADDRESS=127.0.0.1:18085
export DEMO_AGENT_BINARY="$DEMO_STATE_DIR/bin/api-syncagent"
export GOTOOLCHAIN=go1.26.10

./demo/init.sh
make -B api-syncagent BUILD_DEST="$DEMO_STATE_DIR/bin"

python3 demo/validate-status-origins.py --scenario by-owner --ssa --label by-owner
python3 demo/validate-status-origins.py --label client-side
```

The runner checks primary spec/status synchronization, related-resource updates in both directions,
the `watch` behavior, compatibility with existing boolean configurations, disabled status,
server-side admission rules, and primary deletion. The `by-owner` scenario adds the kcp-local owner
reference manually, as described above.

The feature branch alone retains the known forward-status SSA issue addressed by the separate
`fix/ssa-forward-status` branch. To explicitly record that distinction:

```bash
python3 demo/validate-status-origins.py --ssa \
  --cases kcp-kcp,kcp-service,service-service,service-kcp \
  --allow-known-ssa-forward-issue --label ssa-standalone
```

`KNOWN_ISSUE` is recorded separately from `PASS`. With a binary that includes the separate SSA fix,
use `--binary /path/to/combined/api-syncagent` and omit `--allow-known-ssa-forward-issue`.

These are API synchronization checks. Provider reconciliation is simulated with explicit `/status`
writes; the demo does not provision PostgreSQL or validate a production provider deployment.

## Stop the demo

Stop kcp and delete the Kind cluster:

```bash
./demo/cleanup.sh
```

Logs and generated kubeconfigs remain available. Remove `demo/.state` and
`demo/kubeconfigs` manually if a completely fresh environment is required.
