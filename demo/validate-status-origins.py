#!/usr/bin/env python3
"""Exercise the local three-workspace demo using real Kubernetes and kcp APIs."""

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
STATE = Path(os.environ["DEMO_STATE_DIR"])
CONFIGS = Path(os.environ["DEMO_KUBECONFIG_DIR"])
KIND = CONFIGS / "kind.kubeconfig"
CUSTOMER = CONFIGS / "customer.kubeconfig"
APP_PROVIDER = CONFIGS / "application-provider.kubeconfig"
DB_PROVIDER = CONFIGS / "database-provider.kubeconfig"
DB_VW = CONFIGS / "database-provider-virtual-workspace.kubeconfig"
DB = {
    "service": (KIND, "demo", "databases.database.internal.demo"),
    "kcp": (DB_VW, "default", "databases.databases.demo.kcp.io"),
}
APP = {
    "service": (KIND, "demo", "applications.platform.internal.demo"),
    "kcp": (CUSTOMER, "default", "applications.applications.demo.kcp.io"),
}
RUNNING_AGENT = None
CASES = [
    ("kcp-kcp", "kcp", "kcp", True, True),
    ("kcp-service", "kcp", "service", True, True),
    ("service-service", "service", "service", True, True),
    ("service-kcp", "service", "kcp", True, True),
    ("legacy-kcp", "kcp", None, True, True),
    ("legacy-service", "service", None, True, True),
    ("disabled", "service", None, False, True),
    ("omitted", "service", None, None, True),
    ("no-watch", "kcp", "kcp", True, False),
]


def kubectl(config, *args, data=None, check=True):
    result = subprocess.run(
        ["kubectl", "--kubeconfig", str(config), "--request-timeout=15s", *args],
        input=json.dumps(data) if data is not None else None,
        text=True, capture_output=True,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result


def get(location, name):
    config, namespace, resource = location
    result = kubectl(config, "-n", namespace, "get", resource, name, "-o", "json", check=False)
    return json.loads(result.stdout) if result.returncode == 0 else None


def patch(location, name, body, status=False):
    config, namespace, resource = location
    args = ["-n", namespace, "patch", resource, name, "--type=merge", "-p", json.dumps(body)]
    if status:
        args.append("--subresource=status")
    kubectl(config, *args)


def wait(label, predicate, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if RUNNING_AGENT is not None and RUNNING_AGENT.poll() is not None:
            raise RuntimeError("The test agent exited while waiting for " + label)
        result = predicate()
        if result:
            return result
        time.sleep(0.5)
    raise TimeoutError(label)


def value(location, name, section, field):
    return (get(location, name) or {}).get(section, {}).get(field)


def apply(location, name, spec, labels=None):
    config, namespace, resource = location
    group = resource.split(".", 1)[1]
    kind = "Application" if resource.startswith("applications.") else "Database"
    obj = {
        "apiVersion": group + "/v1alpha1", "kind": kind,
        "metadata": {"name": name, "namespace": namespace}, "spec": spec,
    }
    if labels:
        obj["metadata"]["labels"] = labels
    kubectl(config, "apply", "-f", "-", data=obj)


def absent(location, name):
    config, namespace, resource = location
    result = kubectl(config, "-n", namespace, "get", resource, name,
                     "--ignore-not-found", "-o", "json", check=False)
    return result.returncode == 0 and not result.stdout.strip()


def delete(location, name):
    config, namespace, resource = location
    kubectl(config, "-n", namespace, "delete", resource, name,
            "--ignore-not-found", "--wait=false")


def cleanup(name, database):
    delete(APP["kcp"], name)
    wait("primary deletion and cleanup finalizer", lambda: (
        absent(APP["kcp"], name) and absent(APP["service"], name)))
    for location in DB.values():
        delete(location, database)
    wait("test database cleanup", lambda: all(absent(loc, database) for loc in DB.values()))


def bootstrap():
    def published():
        export = json.loads(kubectl(APP_PROVIDER, "get", "apiexport", "applications",
                                    "-o", "json").stdout)
        return export if export.get("spec", {}).get("resources", export.get(
            "spec", {}).get("latestResourceSchemas", [])) else None
    export = wait("Application API publication", published)
    claims = [dict(claim, state="Accepted", selector={"matchAll": True})
              for claim in export["spec"].get("permissionClaims", [])]
    kubectl(CUSTOMER, "patch", "apibinding", "applications", "--type=merge", "-p",
            json.dumps({"spec": {"permissionClaims": claims}}))
    def bound():
        binding = json.loads(kubectl(CUSTOMER, "get", "apibinding", "applications",
                                     "-o", "json").stdout)
        return any(c["type"] == "Ready" and c["status"] == "True"
                   for c in binding.get("status", {}).get("conditions", []))
    wait("Application APIBinding readiness", bound)


def related(origin, status_origin=None, enabled=True, with_watch=True):
    identity = kubectl(DB_PROVIDER, "get", "apiexport", "databases", "-o",
                       "jsonpath={.status.identityHash}").stdout
    item = {
        "identifier": "database", "origin": origin,
        "group": DB[origin][2].split(".", 1)[1], "version": "v1alpha1",
        "resource": "databases", "identityHash": identity,
        "projection": {"group": DB["kcp" if origin == "service" else "service"][2].split(".", 1)[1]},
        "object": {"reference": {"path": "spec.databaseName"}},
    }
    if enabled is not None:
        item["syncStatus"] = enabled
    if status_origin is not None:
        item["syncStatusOrigin"] = status_origin
    if with_watch:
        item["watch"] = {"bySelector": {"matchLabels": {"validation.demo.kcp.io/run": "pr194"}}}
    return item


def configure(item):
    kubectl(KIND, "patch", "publishedresource", "applications", "--type=merge", "-p",
            json.dumps({"spec": {"related": [item]}}))
    time.sleep(2)


def primary_checks(name):
    patch(APP["kcp"], name, {"spec": {"replicas": 3}})
    wait("primary spec forwarding", lambda: value(APP["service"], name, "spec", "replicas") == 3)
    patch(APP["service"], name, {"status": {"phase": "Running"}}, status=True)
    wait("primary status back-sync", lambda: value(APP["kcp"], name, "status", "phase") == "Running")


def matrix_case(case, allow_known):
    label, origin, status_origin, enabled, with_watch = case
    name = "pr194-" + label
    database = name + "-db"
    apply(DB[origin], database, {"engine": "PostgreSQL", "storageGiB": 20})
    apply(APP["kcp"], name, {"replicas": 2, "databaseName": database},
          {"validation.demo.kcp.io/run": "pr194"})
    for side in DB:
        wait("related spec placement on " + side,
             lambda side=side: value(DB[side], database, "spec", "storageGiB") == 20)
    primary_checks(name)
    time.sleep(3)
    authority = status_origin or origin
    receiver = "service" if authority == "kcp" else "kcp"
    expected = {"phase": "Ready-" + label, "endpoint": database + ".demo.svc:5432"}
    primary_rv = get(APP["kcp"], name)["metadata"]["resourceVersion"]
    patch(DB[authority], database, {"status": expected}, status=True)
    if enabled:
        if not with_watch:
            start = time.monotonic()
            while time.monotonic() - start < 10:
                assert value(DB[receiver], database, "status", "phase") is None
                time.sleep(0.5)
            patch(APP["kcp"], name, {"metadata": {"annotations": {
                "validation.demo.kcp.io/reconcile": str(time.time_ns())}}})
        try:
            wait("related status propagation", lambda: (
                (get(DB[receiver], database) or {}).get("status") == expected),
                timeout=12 if allow_known and authority == origin else 120)
        except TimeoutError:
            if not (allow_known and authority == origin and with_watch):
                raise
            patch(APP["kcp"], name, {"spec": {"replicas": 4}})
            wait("forced primary reconciliation", lambda: value(
                APP["service"], name, "spec", "replicas") == 4)
            time.sleep(3)
            assert value(DB[receiver], database, "status", "phase") is None
            return {"status": "KNOWN_ISSUE", "authority_status": expected,
                    "receiver_status": get(DB[receiver], database).get("status"),
                    "reason": "Forward SSA status still absent after explicit primary reconciliation; separate SSA fix required."}
    else:
        patch(APP["kcp"], name, {"spec": {"replicas": 4}})
        wait("primary reconciliation with disabled status", lambda: value(
            APP["service"], name, "spec", "replicas") == 4)
        for _ in range(10):
            assert value(DB[receiver], database, "status", "phase") is None
            time.sleep(0.5)
    patch(DB[origin], database, {"spec": {"storageGiB": 31}})
    if not with_watch:
        patch(APP["kcp"], name, {"metadata": {"annotations": {
            "validation.demo.kcp.io/reconcile": str(time.time_ns())}}})
    destination = "service" if origin == "kcp" else "kcp"
    wait("related spec update after status update", lambda: value(
        DB[destination], database, "spec", "storageGiB") == 31)
    if enabled:
        assert get(DB[receiver], database).get("status") == expected
    return {"status": "PASS", "spec_origin": origin, "status_origin": authority,
            "syncStatus": enabled, "explicit_status_origin": status_origin,
            "watch": with_watch, "spec_storageGiB": 31,
            "authority_status": get(DB[authority], database).get("status"),
            "receiver_status": get(DB[receiver], database).get("status"),
            "primary_changed_during_status_sync": primary_rv != get(
                APP["kcp"], name)["metadata"]["resourceVersion"],
            "primary_spec_forwarded": True, "primary_status_back_synced": True}


def validation_cases():
    base = json.loads(kubectl(KIND, "get", "publishedresource", "applications", "-o", "json").stdout)
    result = []
    cases = [
        ("legacy-kcp-no-watch", related("kcp", enabled=True, with_watch=False), True),
        ("legacy-service-with-watch", related("service"), True),
        ("new-reverse-with-watch", related("service", "kcp"), True),
        ("reverse-without-watch", related("kcp", "service", with_watch=False), False),
        ("origin-without-enable", related("kcp", "service", enabled=None), False),
        ("origin-with-disabled-enable", related("kcp", "service", enabled=False), False),
        ("unknown-status-origin", related("kcp", "unknown"), False),
    ]
    empty_watch = related("kcp", "kcp")
    empty_watch["watch"] = {}
    cases.append(("empty-watch", empty_watch, False))
    old_string = related("kcp")
    old_string["syncStatus"] = "kcp"
    cases.append(("string-syncStatus-rejected", old_string, False))
    expected_errors = {
        "reverse-without-watch": "watch must be configured",
        "origin-without-enable": "syncStatus must be true",
        "origin-with-disabled-enable": "syncStatus must be true",
        "unknown-status-origin": "Unsupported value",
        "empty-watch": "exactly one of byOwner or bySelector must be set",
        "string-syncStatus-rejected": "must be of type boolean",
    }
    for label, item, valid in cases:
        obj = {"apiVersion": base["apiVersion"], "kind": base["kind"],
               "metadata": {"name": "pr194-validation-" + label},
               "spec": {**base["spec"], "related": [item]}}
        response = kubectl(KIND, "apply", "--dry-run=server", "-f", "-", data=obj, check=False)
        assert (response.returncode == 0) == valid, label + ": " + response.stderr
        if not valid:
            assert expected_errors[label] in response.stderr, label + ": " + response.stderr
        result.append({"case": label, "accepted": valid, "status": "PASS",
                       "rejection": response.stderr.strip() if not valid else None})
    return result


def by_owner():
    cleanup("customer-portal", "customer-portal-db")
    response = subprocess.run([str(ROOT / "demo/load-scenario.sh")], text=True,
                              capture_output=True, timeout=420)
    (STATE / "by-owner-scenario.log").write_text(response.stdout + response.stderr)
    if response.returncode:
        raise RuntimeError(response.stdout + response.stderr)
    name, database = "customer-portal", "customer-portal-db"
    snapshots = {side: get(DB[side], database) for side in DB}
    apps = {side: get(APP[side], name) for side in APP}
    assert snapshots["service"]["spec"] == snapshots["kcp"]["spec"]
    assert snapshots["service"]["status"] == snapshots["kcp"]["status"]
    uids = {side: apps[side]["metadata"]["uid"] for side in apps}
    assert uids["service"] != uids["kcp"]
    for side in DB:
        assert snapshots[side]["metadata"]["ownerReferences"][0]["uid"] == uids[side]
    primary_checks(name)
    patch(DB["service"], database, {"spec": {"storageGiB": 31}})
    wait("byOwner service spec watch", lambda: value(DB["kcp"], database, "spec", "storageGiB") == 31)
    patch(DB["kcp"], database, {"status": {
        "phase": "ReadyAgain", "endpoint": "updated.demo.svc:5432"}}, status=True)
    wait("byOwner kcp status watch", lambda: value(
        DB["service"], database, "status", "phase") == "ReadyAgain")
    result = {"status": "PASS", "byOwner_uids_are_cluster_local": True,
              "kcp_owner_installed_manually": True,
              "spec_storageGiB": 31,
              "service_status": get(DB["service"], database)["status"],
              "kcp_status": get(DB["kcp"], database)["status"],
              "primary_spec_forwarded": True, "primary_status_back_synced": True}
    cleanup(name, database)
    return result


def main():
    global RUNNING_AGENT
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=["matrix", "by-owner"], default="matrix")
    parser.add_argument("--ssa", action="store_true")
    parser.add_argument("--binary", default=os.environ["DEMO_AGENT_BINARY"])
    parser.add_argument("--label", required=True)
    parser.add_argument("--cases")
    parser.add_argument("--allow-known-ssa-forward-issue", action="store_true")
    args = parser.parse_args()
    if args.allow_known_ssa_forward_issue and not args.ssa:
        parser.error("The known SSA issue option requires --ssa")
    selected = set(args.cases.split(",")) if args.cases else {case[0] for case in CASES}
    if selected - {case[0] for case in CASES}:
        parser.error("Unknown case names")
    if args.scenario == "matrix" and len(selected) > 1:
        combined = {"label": args.label, "binary": args.binary, "ssa": args.ssa,
                    "agent_restarted_between_scenarios": True, "results": []}
        for case in CASES:
            if case[0] not in selected:
                continue
            child_label = args.label + "-" + case[0]
            command = [sys.executable, str(Path(__file__).resolve()),
                       "--binary", args.binary, "--label", child_label, "--cases", case[0]]
            if args.ssa:
                command.append("--ssa")
            if args.allow_known_ssa_forward_issue:
                command.append("--allow-known-ssa-forward-issue")
            child = subprocess.run(command)
            child_report = json.loads((STATE / (child_label + ".json")).read_text())
            combined["results"].extend(child_report["results"])
            combined.setdefault("admission", child_report.get("admission", []))
            if child_report.get("error"):
                combined["error"] = child_report["error"]
            (STATE / (args.label + ".json")).write_text(json.dumps(combined, indent=2) + "\n")
            if child.returncode:
                return child.returncode
        return 0
    host, port = os.environ["DEMO_HEALTH_ADDRESS"].rsplit(":", 1)
    try:
        connection = socket.create_connection((host, int(port)), timeout=1)
    except OSError:
        pass
    else:
        connection.close()
        parser.error("The test agent port is already in use; stop that agent or choose another port.")
    if args.scenario == "matrix":
        case = next(case for case in CASES if case[0] in selected)
        configure(related(*case[1:]))
    else:
        item = related("service", "kcp")
        item["watch"] = {"byOwner": {}}
        configure(item)
    report = {"label": args.label, "binary": args.binary, "ssa": args.ssa, "results": []}
    output = STATE / (args.label + ".json")
    log = (STATE / (args.label + "-agent.log")).open("w")
    agent = subprocess.Popen([
        args.binary, "--agent-name", "application-provider",
        "--apiexportendpointslice-ref", "applications", "--enable-leader-election=false",
        "--enable-server-side-apply=" + str(args.ssa).lower(),
        "--health-address", os.environ["DEMO_HEALTH_ADDRESS"],
        "--metrics-address", os.environ["DEMO_METRICS_ADDRESS"],
        "--kubeconfig", str(KIND), "--kcp-kubeconfig", str(APP_PROVIDER),
        "--namespace", "api-syncagent-demo", "--log-debug=true", "--log-format=Console",
    ], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    RUNNING_AGENT = agent
    try:
        def ready():
            if agent.poll() is not None:
                raise RuntimeError("Agent exited; inspect " + str(log.name))
            try:
                host, port = os.environ["DEMO_HEALTH_ADDRESS"].rsplit(":", 1)
                with socket.create_connection((host, int(port)), timeout=2):
                    return True
            except OSError:
                return False
        wait("agent HTTP listener", ready)
        bootstrap()
        if args.scenario == "by-owner":
            result = by_owner()
            report["results"].append({"case": "by-owner-reverse", **result})
            print("PASS by-owner-reverse", flush=True)
        else:
            report["admission"] = validation_cases()
            print("PASS admission checks: " + str(len(report["admission"])), flush=True)
            for case in CASES:
                if case[0] not in selected:
                    continue
                start = time.monotonic()
                try:
                    result = matrix_case(case, args.allow_known_ssa_forward_issue)
                    cleanup("pr194-" + case[0], "pr194-" + case[0] + "-db")
                    result["primary_deletion_cleanup"] = True
                except Exception as error:
                    result = {"status": "FAIL", "error": str(error)}
                report["results"].append({"case": case[0], "seconds": round(time.monotonic() - start, 2), **result})
                output.write_text(json.dumps(report, indent=2) + "\n")
                print(result["status"] + " " + case[0] + " " + str(result.get("error", "")), flush=True)
                if result["status"] == "FAIL":
                    break
    except Exception as error:
        report["error"] = str(error)
        print("FAIL " + str(error), flush=True)
    finally:
        agent.terminate()
        try:
            agent.wait(timeout=15)
        except subprocess.TimeoutExpired:
            agent.kill()
            agent.wait()
        log.close()
        output.write_text(json.dumps(report, indent=2) + "\n")
        print("Report: " + str(output), flush=True)
    return int(bool(report.get("error")) or any(row["status"] == "FAIL" for row in report["results"]))


if __name__ == "__main__":
    sys.exit(main())
