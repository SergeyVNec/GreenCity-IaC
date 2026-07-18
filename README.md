# GreenCity — AWS DevOps Platform

Full production-style deployment of the **GreenCity** application (3 services:
`backcore`, `backuser`, `frontend`) on AWS, built entirely as **Infrastructure as
Code** with a complete CI/CD pipeline, observability, security, autoscaling, and an
AI **voice ChatOps** interface.

Everything is reproducible from scratch on any AWS account — see [SETUP.md](SETUP.md).
The rendered architecture diagram is in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 1. What it is (high level)

```
                    ┌──────────────────────── AWS account ────────────────────────┐
   GitHub (3 repos) │                                                              │
        │ pollSCM   │   Jenkins ──► CodeBuild ──► ECR ──► k3s deploy                │
        ▼           │   (CI orch)  (build+CCI+SCA)  (images)  (kubectl)            │
   Jenkins polls    │                                                              │
                    │   VPC · RDS(PostgreSQL) · ALB · CloudWatch · Secrets Manager  │
                    │                                                              │
                    │   k3s cluster (4 EC2 nodes):                                  │
                    │     control-plane │ agent-1 │ agent-2 │ observability node    │
                    │        ├─ app: backcore, backuser, frontend×2, rabbitmq       │
                    │        ├─ security: PSS + SecurityContext + Falco             │
                    │        ├─ scaling: HPA (backcore/backuser/frontend)           │
                    │        └─ observability: Splunk, OTel, Prometheus+Grafana,    │
                    │                          Datadog, SonarQube                   │
                    │        └─ ChatOps: MCP server + Hermes agent                  │
                    └──────────────────────────────────────────────────────────────┘
                                        ▲
                     Windows voice agent │ (Whisper → gpt-4o-mini+MCP → ElevenLabs)
```

## 2. Technology choices at a glance

| Area | Choice | Why (short — full reasoning in DECISIONS.md) |
|---|---|---|
| IaC | **Terraform**, modular, S3 remote state + native locking | mentor requirement; PR-workflow; no DynamoDB needed (`use_lockfile`) |
| Kubernetes | **k3s on EC2** (not EKS) | EKS control plane costs ~$73/mo; k3s is free and light |
| OS | **Amazon Linux 2023** (auto-selected AMI) | AWS-native, current, region-portable via `data.aws_ami` |
| CI orchestration | **Jenkins** (pollSCM) | no rights to add GitHub webhooks → polling instead |
| Build | **AWS CodeBuild** | isolated cloud builds, privileged Docker; Jenkins host stays clean |
| Registry | **ECR** (scan-on-push + lifecycle) | managed, private, integrates with IAM |
| Database | **RDS PostgreSQL** (managed master password → Secrets Manager) | no DB password in code or state |
| CCI | **SonarQube** self-hosted + custom Quality Gate | SonarCloud needs repo-admin rights we don't have |
| SCA | **Trivy** (deps + image) | free, fast, container-native |
| Observability | CloudWatch + Prometheus/Grafana + Splunk + OpenTelemetry + Datadog + Falco | assignment requires this breadth; each covers a different angle |
| ChatOps | **MCP server + Hermes/gpt-4o-mini** + voice | model-agnostic ops interface over the cluster |

## 3. Repository layout

```
GreenCityAWS/
├─ bootstrap/          Terraform → S3 bucket for the remote state (run once)
├─ main.tf outputs.tf variables.tf terraform.tf   root Terraform (AWS infra)
├─ terraform.tfvars.example
├─ modules/
│   ├─ network   VPC, 2 public subnets, IGW, routing
│   ├─ security  security groups (alb, app, rds, jenkins, k3s)
│   ├─ ecr       3 repos, scan-on-push, lifecycle policy
│   ├─ rds       PostgreSQL, managed password → Secrets Manager
│   ├─ iam       instance roles / profiles
│   ├─ ec2       standalone Docker app host (legacy path, still built)
│   ├─ alb       ALB + 3 target groups/listeners (80/8080/8060)
│   ├─ codebuild CodeBuild project + inline buildspec (CI + CCI + SCA)
│   ├─ deploy    SSM document to (re)deploy containers on the app host
│   ├─ jenkins   Jenkins EC2 + JCasC polling jobs
│   ├─ monitoring CloudWatch alarms, dashboard, SNS
│   └─ k3s       cluster (server + agents + observability node) + manifests/
│        └─ manifests/  greencity, hpa, falco, datadog, splunk, otel,
│                       otel-logs, prometheus-grafana, sonarqube, mcp/, hermes/
├─ setup-cluster.ps1   deploys the whole k8s layer on top of the running cluster
├─ setup-cluster.env.example
├─ windows-agent/      native Windows voice assistant (tray app)
└─ SETUP.md            from-scratch deployment guide
```

## 4. CI/CD pipeline

```
git push ─► Jenkins (pollSCM every ~1 min) ─► CodeBuild:
   for each of backcore / backuser / frontend:
     git clone ─► SonarQube analysis ─► Quality Gate ──PASS──► build image ─► Trivy scan ─► push to ECR
                                          └──FAIL──► build red, no deploy
   ─► Jenkins ─► SSM deploy (Docker host)  +  k3s pulls :latest
   ─► Discord notification (OK / FAILED)
```

- **CCI (SonarQube)**: analysis runs in a Maven/scanner container; `-Dsonar.qualitygate.wait=true`
  makes a failing gate return non-zero → `set -e` fails the build → deploy is skipped.
  Gate = custom **"GreenCity way"** (blocks new bugs/vulnerabilities/blockers/duplication,
  does **not** require coverage since tests are skipped in the pipeline).
- **SCA (Trivy)**: filesystem (dependencies) + built-image scan for HIGH/CRITICAL CVEs.
- Base images pulled from **ECR Public** to avoid Docker Hub anonymous-pull rate limits (429).
- Frontend nginx **reverse-proxies** `/mvp`, `/ownSecurity`, `/user`, `/googleSecurity` to the
  backends (same-origin) and clears the `Origin` header → no CORS (backend `CorsFilter` returned 403).

## 5. Kubernetes layer (k3s)

- **Nodes**: 1 control-plane + 2 agents (`t3.small`, run the app) + 1 observability node
  (`m7i-flex.large`, 8 GB — runs Splunk/Grafana/Prometheus/SonarQube). Control-plane is also
  `m7i-flex.large` (it OOM'd on 2 GB under cluster churn).
- **ECR auth**: each node writes `/etc/rancher/k3s/registries.yaml` with a runtime ECR token
  (fetched via the node IAM role). The token lives ~12 h, so a **systemd timer refreshes it every 6 h**.
- **Pod Security Standards**: namespace `greencity` is `enforce=baseline`, `warn/audit=restricted`.
- **SecurityContext**: Java backends drop **all** Linux capabilities + seccomp `RuntimeDefault`;
  rabbitmq/nginx keep `SETUID/SETGID/CHOWN` (their entrypoints need them) — dropping all made them crash.
- **Autoscaling**: HPA for backcore/backuser (1→3) and frontend (2→4) on 70% CPU.
  metrics-server ships with k3s.

## 6. Observability (six angles)

| Tool | What it covers |
|---|---|
| **CloudWatch** | infra health of the Docker host: CPU / StatusCheck alarms, dashboard, container logs |
| **Prometheus + Grafana** | cluster metrics (cAdvisor per-pod) + a provisioned GreenCity dashboard |
| **Splunk** | central logs (OTel filelog → HEC, index `otel_logs`) + metrics (index `otel_metrics`) |
| **OpenTelemetry** | vendor-neutral collector: hostmetrics + filelog DaemonSet → Splunk; prometheus exporter → Prometheus |
| **Datadog** | SaaS APM/agents (logs + processes) → datadoghq.eu |
| **Falco** | runtime security (eBPF) — alerts on suspicious syscalls (e.g. reading `/etc/shadow`) |

## 7. Security & secret management

- **RDS master password**: AWS-generated, stored in **Secrets Manager** — never in code or state.
- **k8s Secrets** (`secretKeyRef`) for every app/observability password (db, Splunk, Grafana, Sonar, MCP…).
- **SSM Parameter Store** (SecureString) for the SonarQube CI token consumed by CodeBuild.
- **API keys** (Groq/ElevenLabs/OpenRouter/Datadog) live in `setup-cluster.env` (git-ignored).
- Least-privilege IAM per role; ECR repos scan images on push; PSS + SecurityContext + Falco at runtime.

## 8. AI ChatOps + voice assistant

- **MCP server** (`greencity-ops`) exposes 9 tools over the Model Context Protocol, bearer-guarded:
  read-only (`get_pod_status`, `query_prometheus`, `search_splunk`, `get_quality_gate`,
  `get_falco_alerts`) and actions (`scale_deployment`, `restart_pod`, `rollout_restart`,
  `trigger_build`).
- **Hermes agent** bridges an LLM (gpt-4o-mini via OpenRouter) to the MCP tools and serves a
  web UI. Model is pluggable via env.
- **Windows voice agent** (`windows-agent/`): wake word (openWakeWord, offline) → Groq Whisper
  (STT) → gpt-4o-mini + MCP → ElevenLabs (TTS). Runs as a tray app, autostarts with Windows,
  needs **no API keys on the client** (all live in the cluster).

## 9. Access (per-deployment — read from `terraform output`)

```
Splunk      http://<observability_eip>:30800   admin / Splunk_2026!
Grafana     http://<observability_eip>:30300   admin / Grafana_2026!
SonarQube   http://<observability_eip>:30900   admin / SonarAdmin_2026!
MCP server  http://<observability_eip>:30880/mcp   (Bearer token printed by setup-cluster.ps1)
ChatOps     http://<observability_eip>:30890
App (ALB)   terraform output frontend_url
Jenkins     terraform output jenkins_url
```
`<observability_eip>` = `terraform output observability_eip`.

## 10. Deploy / teardown

Full instructions in **[SETUP.md](SETUP.md)**. In short:

```powershell
cd bootstrap; terraform init; terraform apply            # state bucket
cd ..; terraform init -backend-config="bucket=<name>"; terraform apply   # AWS infra
copy setup-cluster.env.example setup-cluster.env         # your API keys
.\setup-cluster.ps1                                      # k8s layer
```
Teardown: `terraform destroy` (main) → delete `/greencity/sonar-*` SSM params → destroy `bootstrap/`.

## 11. Cost

~**$260/month** on-demand list price (2× m7i-flex.large, 4× t3.small, RDS, ALB, public IPv4).
On a new-style AWS **Free Plan** account these instance types are free-tier-eligible and draw
from credits. Cut cost with `splunk_node_enabled=false`, smaller nodes, or `terraform destroy`
after a demo.
