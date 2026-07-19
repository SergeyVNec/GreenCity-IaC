"""GreenCity Ops MCP server.

Exposes the project's observability + operations surface to an MCP client
(Claude Desktop / Claude Code) over streamable HTTP. Read-only tools query
Prometheus / Splunk / SonarQube / Kubernetes; action tools drive the cluster
and CI. A bearer token guards every request.
"""
import os
import json
import datetime

import requests
import urllib3
from kubernetes import client, config as kconfig
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

urllib3.disable_warnings()  # Splunk mgmt port uses a self-signed cert

# --- Configuration (from env / mounted Secret) ---
PROM = os.environ.get("PROM_URL", "http://prometheus.observability.svc.cluster.local:9090")
SPLUNK_MGMT = os.environ.get("SPLUNK_MGMT", "https://splunk.observability.svc.cluster.local:8089")
SPLUNK_USER = os.environ.get("SPLUNK_USER", "admin")
SPLUNK_PASS = os.environ.get("SPLUNK_PASSWORD", "")
SONAR = os.environ.get("SONAR_URL", "http://sonarqube.observability.svc.cluster.local:9000")
SONAR_TOKEN = os.environ.get("SONAR_TOKEN", "")
CODEBUILD_PROJECT = os.environ.get("CODEBUILD_PROJECT", "greencity-build")
REGION = os.environ.get("AWS_REGION", "us-east-1")
BEARER = os.environ.get("MCP_BEARER_TOKEN", "")
RDS_HOST = os.environ.get("RDS_HOST", "")
DB_NAME = os.environ.get("DB_NAME", "greencity")
DB_USER = os.environ.get("DB_USER", "greencity")
DB_SECRET_ARN = os.environ.get("DB_SECRET_ARN", "")
_DB_PASS = None

kconfig.load_incluster_config()
_apps = client.AppsV1Api()
_core = client.CoreV1Api()

# Accessed via NodePort IP, so relax the SDK's DNS-rebinding Host/Origin check.
# The bearer-token middleware below is what actually guards the server.
_security = TransportSecuritySettings(enable_dns_rebinding_protection=False)
mcp = FastMCP("greencity-ops", stateless_http=True, transport_security=_security)


# ============================ READ-ONLY TOOLS ============================
@mcp.tool()
def get_pod_status(namespace: str = "greencity") -> str:
    """List pods in a namespace with phase, readiness and restart counts."""
    out = []
    for p in _core.list_namespaced_pod(namespace).items:
        cs = p.status.container_statuses or []
        ready = sum(1 for c in cs if c.ready)
        restarts = sum(c.restart_count for c in cs)
        out.append({
            "name": p.metadata.name,
            "phase": p.status.phase,
            "ready": f"{ready}/{len(cs)}",
            "restarts": restarts,
            "node": p.spec.node_name,
        })
    return json.dumps(out, indent=2)


@mcp.tool()
def query_prometheus(promql: str) -> str:
    """Run an instant PromQL query against Prometheus and return the raw result."""
    r = requests.get(f"{PROM}/api/v1/query", params={"query": promql}, timeout=15)
    return r.text[:6000]


@mcp.tool()
def search_splunk(query: str, index: str = "otel_logs", count: int = 20) -> str:
    """Run a one-shot Splunk search. `query` is appended after `search index=<index>`."""
    spl = f"search index={index} {query} | head {count}"
    r = requests.post(
        f"{SPLUNK_MGMT}/services/search/jobs",
        auth=(SPLUNK_USER, SPLUNK_PASS), verify=False, timeout=40,
        data={"search": spl, "exec_mode": "oneshot", "output_mode": "json"},
    )
    return r.text[:6000]


@mcp.tool()
def get_quality_gate(project_key: str) -> str:
    """Return the SonarQube Quality Gate status for a project (e.g. greencity-backcore)."""
    r = requests.get(
        f"{SONAR}/api/qualitygates/project_status",
        params={"projectKey": project_key}, auth=(SONAR_TOKEN, ""), timeout=15,
    )
    return r.text[:4000]


@mcp.tool()
def get_falco_alerts(count: int = 20) -> str:
    """Return recent Falco runtime-security alerts (Falco JSON logs land in Splunk otel_logs)."""
    spl = f'search index=otel_logs falco priority | head {count}'
    r = requests.post(
        f"{SPLUNK_MGMT}/services/search/jobs",
        auth=(SPLUNK_USER, SPLUNK_PASS), verify=False, timeout=40,
        data={"search": spl, "exec_mode": "oneshot", "output_mode": "json"},
    )
    return r.text[:6000]


def _db_password() -> str:
    global _DB_PASS
    if _DB_PASS is None:
        import boto3
        sm = boto3.client("secretsmanager", region_name=REGION)
        _DB_PASS = json.loads(sm.get_secret_value(SecretId=DB_SECRET_ARN)["SecretString"])["password"]
    return _DB_PASS


@mcp.tool()
def query_db(sql: str) -> str:
    """Query the GreenCity application PostgreSQL database (READ-ONLY SELECT).
    USE THIS for any question about application data: registered users, how many
    users, emails, accounts, records in a table. Table `users` has columns
    id, email, name. Examples: 'SELECT count(*) FROM users',
    'SELECT id, email, name FROM users ORDER BY id DESC'. Only SELECT is allowed."""
    if not RDS_HOST or not DB_SECRET_ARN:
        return "database access not configured (RDS_HOST/DB_SECRET_ARN)"
    s = sql.strip().rstrip(";")
    low = s.lower()
    if not low.startswith("select"):
        return "only SELECT queries are allowed"
    if any(k in low for k in (";", "insert ", "update ", "delete ", "drop ", "alter ",
                              "truncate ", "create ", "grant ", "revoke ", "copy ")):
        return "query rejected: read-only SELECT only"
    if " limit " not in low:
        s += " LIMIT 200"
    import pg8000.native
    con = pg8000.native.Connection(user=DB_USER, host=RDS_HOST, database=DB_NAME,
                                   password=_db_password(), port=5432, timeout=15)
    try:
        rows = con.run(s)
        cols = [c["name"] for c in con.columns]
        return json.dumps([dict(zip(cols, r)) for r in rows], indent=2, default=str)
    except Exception as e:
        return f"query error: {e}"
    finally:
        con.close()


@mcp.tool()
def get_pod_logs(pod_name: str, namespace: str = "greencity", lines: int = 50) -> str:
    """Return the last N log lines of a pod (direct, not via Splunk)."""
    try:
        return _core.read_namespaced_pod_log(pod_name, namespace, tail_lines=lines)[:6000]
    except Exception as e:
        return f"error: {e}"


@mcp.tool()
def list_deployments(namespace: str = "greencity") -> str:
    """List deployments in a namespace with desired/ready replica counts."""
    out = []
    for d in _apps.list_namespaced_deployment(namespace).items:
        out.append({"name": d.metadata.name,
                    "desired": d.spec.replicas,
                    "ready": d.status.ready_replicas or 0})
    return json.dumps(out, indent=2)


@mcp.tool()
def get_recent_builds(count: int = 5) -> str:
    """Recent CodeBuild pipeline runs with status and start time."""
    import boto3
    cb = boto3.client("codebuild", region_name=REGION)
    ids = cb.list_builds_for_project(projectName=CODEBUILD_PROJECT, sortOrder="DESCENDING").get("ids", [])[:count]
    if not ids:
        return "no builds found"
    builds = cb.batch_get_builds(ids=ids)["builds"]
    out = [{"id": b["id"].split(":")[-1][:8], "status": b["buildStatus"],
            "start": str(b.get("startTime", ""))[:19]} for b in builds]
    return json.dumps(out, indent=2)


# ============================== ACTION TOOLS ==============================
@mcp.tool()
def scale_deployment(name: str, replicas: int, namespace: str = "greencity") -> str:
    """Set the replica count of a Deployment."""
    _apps.patch_namespaced_deployment_scale(name, namespace, {"spec": {"replicas": replicas}})
    return f"scaled {namespace}/{name} to {replicas} replicas"


@mcp.tool()
def restart_pod(pod_name: str, namespace: str = "greencity") -> str:
    """Delete a pod so its controller recreates it."""
    _core.delete_namespaced_pod(pod_name, namespace)
    return f"deleted pod {namespace}/{pod_name} (controller will recreate it)"


@mcp.tool()
def rollout_restart(name: str, namespace: str = "greencity") -> str:
    """Trigger a rolling restart of a Deployment (picks up a fresh image from ECR)."""
    stamp = datetime.datetime.utcnow().isoformat() + "Z"
    patch = {"spec": {"template": {"metadata": {"annotations": {
        "kubectl.kubernetes.io/restartedAt": stamp}}}}}
    _apps.patch_namespaced_deployment(name, namespace, patch)
    return f"rollout restart triggered for {namespace}/{name}"


@mcp.tool()
def trigger_build(project: str = "") -> str:
    """Start a CodeBuild run (CI + SonarQube CCI + Trivy SCA + image push)."""
    import boto3
    cb = boto3.client("codebuild", region_name=REGION)
    b = cb.start_build(projectName=project or CODEBUILD_PROJECT)
    return f"started CodeBuild {b['build']['id']} (status {b['build']['buildStatus']})"


# --- Streamable HTTP app + bearer-token auth ---
app = mcp.streamable_http_app()

from starlette.middleware.base import BaseHTTPMiddleware  # noqa: E402
from starlette.responses import JSONResponse  # noqa: E402


class BearerAuth(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        if BEARER and request.url.path.startswith("/mcp"):
            if request.headers.get("authorization", "") != f"Bearer {BEARER}":
                return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


app.add_middleware(BearerAuth)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
