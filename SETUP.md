# GreenCity AWS — Setup from scratch

Deploy the whole stack on **your own** AWS account. Nothing here is tied to the
original account — the state bucket, AMI, account IDs and domain are all derived
at run time. You do **not** need anyone else's Terraform state.

## What gets built

```
bootstrap/            Terraform → S3 bucket for remote state (greencity-tfstate-<account>)
  (main root)         Terraform → VPC, RDS, ECR, ALB, EC2 app, Jenkins, CodeBuild,
                                  CloudWatch, k3s (server + 2 agents + observability node)
setup-cluster.ps1     PowerShell → k8s layer on top of the running cluster:
                                  app, HPA, Falco, Datadog, Splunk, OpenTelemetry,
                                  Prometheus+Grafana, SonarQube, MCP server, ChatOps
```

## Prerequisites

- **Terraform ≥ 1.11** (native S3 state locking), **AWS CLI v2**, **PowerShell**.
  - Windows: PowerShell is built in.
  - **Linux / macOS**: install **PowerShell 7** (`pwsh`) — the script is cross-platform.
    `brew install powershell` (macOS) or see learn.microsoft.com/powershell for Linux packages.
    Then run it with `pwsh ./setup-cluster.ps1` instead of `.\setup-cluster.ps1`.
- AWS credentials configured (`aws configure`) with rights to create the above.
- Region with Amazon Linux 2023 (any; default `us-east-1`).
- Optional API keys for the voice/ChatOps layer (Groq, ElevenLabs, OpenRouter,
  Datadog). Without them the cluster still comes up; only those integrations idle.

> Note on instance types: the control-plane and observability nodes use
> `m7i-flex.large` (8 GB). On a new-style AWS **Free Plan** account only
> free-tier-eligible types are allowed — these are. On a normal account they bill
> normally (~$260/mo for the whole stack on-demand).

## 1. Create the state bucket

```powershell
cd bootstrap
terraform init
terraform apply -auto-approve
terraform output state_bucket      # e.g. greencity-tfstate-123456789012 — copy it
cd ..
```

## 2. Deploy the AWS infrastructure

```powershell
# point the backend at YOUR bucket from step 1
terraform init -backend-config="bucket=<state_bucket-from-step-1>"

# optional: copy terraform.tfvars.example -> terraform.tfvars and set region/domain/email
terraform apply -auto-approve        # ~12-15 min (RDS is the slow part)
```

## 3. Configure the cluster (k8s layer)

```powershell
copy setup-cluster.env.example setup-cluster.env   # (cp on Linux/macOS)
notepad setup-cluster.env            # paste your Groq/ElevenLabs/OpenRouter/Datadog keys
.\setup-cluster.ps1                  # Windows   — ~25-40 min (Splunk/Sonar init + first build)
# pwsh ./setup-cluster.ps1           # Linux/macOS
```

The script reads Terraform outputs (new RDS endpoint, EIP, ECR registry), fills
them into the manifests, creates all secrets, deploys every component, sets up
Splunk indexes + the SonarQube "GreenCity way" quality gate, and kicks off the
first CodeBuild. At the end it prints all URLs and the generated MCP token.

## 4. Point external things at the new deployment

- **Windows voice agent** (`windows-agent/.env`): set
  `GREENCITY_BACKEND=http://<observability_eip>:30890`.

## 5. Optional configuration

### Google sign-in (real OAuth)

The frontend is built with a **placeholder** `REACT_APP_GOOGLE_CLIENT_ID`, so the site
opens but the "Sign in with Google" button won't actually work. For working Google
login:

1. Create an **OAuth 2.0 Client ID** in the
   [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
   (type *Web application*). Add your site origin(s) to **Authorized JavaScript
   origins** — the ALB URL and/or your domain.
2. Put the ID in `terraform.tfvars`:
   ```hcl
   google_client_id = "1234567890-abc123....apps.googleusercontent.com"
   ```
3. Apply and rebuild the frontend so the new value is baked in:
   ```powershell
   terraform apply -auto-approve -target='module.codebuild'
   aws codebuild start-build --project-name greencity-build --region us-east-1
   ```
   Jenkins auto-deploys the new image to the app host after the build; to redeploy
   immediately, run the deploy document by hand:
   ```powershell
   aws ssm send-command --document-name greencity-deploy --region us-east-1 `
     --instance-ids (terraform output -raw app_instance_id)
   ```

### Custom domain via Cloudflare (with HTTPS)

The ALB is plain HTTP. Cloudflare gives you a nice domain **and free HTTPS** in front
of it, with no cert to manage on AWS.

1. **Add your domain to Cloudflare** (Add a Site) and, at your registrar (e.g. nic.ua),
   change the domain's **nameservers** to the two Cloudflare gives you. Wait for it to
   go *Active* (minutes to a few hours).
2. **DNS record** in Cloudflare → *DNS*:
   - Type **CNAME**, Name `@` (or a subdomain like `app`), Target =
     `terraform output alb_dns_name`, Proxy status **Proxied** (orange cloud).
   - Root-domain CNAME is fine on Cloudflare (it flattens it automatically).
3. **SSL/TLS mode = Flexible** (Cloudflare → *SSL/TLS* → *Overview*). Browser↔Cloudflare
   is HTTPS; Cloudflare↔ALB stays HTTP — no certificate needed on the ALB.
4. **Rebuild the frontend for the domain** so API calls and the same-origin nginx proxy
   use it (avoids CORS). Set the origin and rebuild:
   ```hcl
   # terraform.tfvars
   frontend_api_url = "https://your-domain"
   ```
   ```powershell
   terraform apply -auto-approve -target='module.codebuild'
   aws codebuild start-build --project-name greencity-build --region us-east-1
   ```
5. Open `https://your-domain`. If Google login is set up, add the domain to the OAuth
   *Authorized JavaScript origins* too.

> Note: the ALB DNS name changes on every `terraform destroy`/`apply`, so update the
> Cloudflare CNAME target after a rebuild.

## Teardown

```powershell
terraform destroy -auto-approve                   # 1. main infra (state must still exist!)
cd bootstrap && terraform destroy -auto-approve    # 2. finally the state bucket
```

`terraform destroy` removes **everything** it created — EC2, RDS, ALB, ECR, IAM,
CloudWatch, Secrets Manager, VPC, and the SonarQube SSM parameters. Terminated EC2
instances linger in the console for ~1 h and then clear themselves (they can't and
needn't be deleted manually). Order matters: never delete the state bucket before
`terraform destroy` — Terraform needs the state to know what to remove.

## Gotchas already handled

- **ECR auth in k3s** expires ~12 h → a systemd timer on every node refreshes it
  every 6 h (baked into the node user_data).
- **CI Quality Gate**: the default "Sonar way" requires 80 % coverage on new code;
  since tests are skipped in the pipeline that is unreachable, so setup-cluster.ps1
  installs a realistic "GreenCity way" gate (blocks new bugs/vulns/blockers, not
  coverage). Still a hard, blocking gate.
- **Docker Hub 429**: base images are pulled from ECR Public (no rate limit).
- **HPA vs manual scale**: deployments with an HPA ignore manual `scale` — the HPA
  owns the replica count. Scale by load, or raise `minReplicas`.
- **HPA on t3.small**: scaling a Java backend to 3 replicas can OOM 2 GB agents;
  that is a node-capacity limit, not an HPA fault. Use bigger agents for real load.
