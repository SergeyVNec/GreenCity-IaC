<#
GreenCity - full bootstrap of the k8s / observability / ChatOps layer.

Terraform builds the AWS layer; everything inside the cluster (manifests,
secrets, Splunk indexes, SonarQube setup, CI wiring) is applied by this script.
Run it after `terraform apply` - or with -WithTerraform to do both.

    copy setup-cluster.env.example setup-cluster.env   # put your API keys there
    .\setup-cluster.ps1 -WithTerraform

Idempotent: safe to re-run. Takes ~25-40 min from a clean destroy
(RDS ~10m, k3s ~4m, Splunk/Sonar init ~6m, image build ~12m).
#>
param(
    [string]$Region = "us-east-1",
    [switch]$WithTerraform,   # run `terraform apply` first
    [switch]$SkipBuild        # don't trigger CodeBuild at the end
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
# Forward slashes work on Windows and Linux/macOS (PowerShell 7 / .NET normalises them).
$manifests = Join-Path $root "modules/k3s/manifests"
$tmpDir    = [System.IO.Path]::GetTempPath()   # cross-platform temp dir

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

# ---------- API keys (from setup-cluster.env, gitignored) ----------
$envFile = Join-Path $root "setup-cluster.env"
if (-not (Test-Path $envFile)) { $envFile = Join-Path $root "bootstrap.env" }  # legacy name
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match "^\s*[A-Z_]+\s*=" } | ForEach-Object {
        $k, $v = $_ -split "=", 2
        Set-Item -Path "env:$($k.Trim())" -Value $v.Trim()
    }
    Info "loaded keys from $(Split-Path $envFile -Leaf)"
} else {
    Write-Warning "setup-cluster.env not found - Datadog/Groq/ElevenLabs/OpenRouter secrets will be placeholders."
}

# ---------- 1. Terraform ----------
if ($WithTerraform) {
    Step "terraform apply"
    Push-Location $root
    terraform apply -auto-approve
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed" }
    Pop-Location
}

Step "reading terraform outputs"
Push-Location $root
$tf = terraform output -json | ConvertFrom-Json
Pop-Location
$ServerId    = $tf.k3s_server_instance_id.value
$RdsEndpoint = $tf.rds_endpoint.value
$DbSecretArn = $tf.db_secret_arn.value
$EcrRegistry = ($tf.ecr_repository_urls.value.backcore -split "/")[0]
$ObsIp       = $tf.observability_eip.value
if (-not $ObsIp) { throw "observability_eip output is empty - is module.k3s.aws_eip.splunk created?" }
Info "server=$ServerId  rds=$RdsEndpoint"
Info "ecr=$EcrRegistry  obs-ip=$ObsIp"

# ---------- helpers ----------
function Invoke-Node([string[]]$Commands, [int]$TimeoutSec = 900) {
    $tmp = Join-Path $tmpDir "gc-bootstrap.json"
    ([ordered]@{ commands = $Commands } | ConvertTo-Json -Depth 5 -Compress) | Out-File $tmp -Encoding ascii
    $cid = aws ssm send-command --region $Region --instance-ids $ServerId `
        --document-name "AWS-RunShellScript" --parameters "file://$tmp" `
        --query "Command.CommandId" --output text
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 6
        $st = aws ssm get-command-invocation --command-id $cid --instance-id $ServerId --region $Region --query "Status" --output text 2>$null
    } while (($st -eq "InProgress" -or $st -eq "Pending" -or -not $st) -and (Get-Date) -lt $deadline)
    $out = aws ssm get-command-invocation --command-id $cid --instance-id $ServerId --region $Region --query "StandardOutputContent" --output text 2>$null
    $err = aws ssm get-command-invocation --command-id $cid --instance-id $ServerId --region $Region --query "StandardErrorContent" --output text 2>$null
    if ($st -ne "Success") { Write-Warning "SSM $st`n$err" }
    return $out
}

function Apply-Manifest([string]$File, [hashtable]$Subs = @{}) {
    $path = Join-Path $manifests $File
    $text = [IO.File]::ReadAllText($path)
    foreach ($k in $Subs.Keys) { $text = $text.Replace($k, $Subs[$k]) }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    Info "apply $File"
    Invoke-Node @("echo '$b64' | base64 -d | k3s kubectl apply -f -") | Out-Null
}

function Wait-ForNodes {
    Step "waiting for k3s nodes"
    for ($i = 0; $i -lt 40; $i++) {
        $out = (Invoke-Node @("k3s kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready '")) -join "`n"
        $n = if ($out -match '(\d+)') { [int]$Matches[1] } else { 0 }
        if ($n -ge 4) { Info "$n nodes Ready"; return }
        Info "nodes Ready: $n - waiting..."
        Start-Sleep -Seconds 20
    }
    Write-Warning "not all nodes became Ready - continuing anyway"
}

# ---------- 2. wait for the cluster ----------
Wait-ForNodes

# ---------- 3. secrets ----------
Step "secrets"
$dbPass = (aws secretsmanager get-secret-value --secret-id $DbSecretArn --region $Region --query "SecretString" --output text | ConvertFrom-Json).password
$mcpToken = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
$groq   = if ($env:GROQ_API_KEY)       { $env:GROQ_API_KEY }       else { "REPLACE_ME" }
$eleven = if ($env:ELEVENLABS_API_KEY) { $env:ELEVENLABS_API_KEY } else { "REPLACE_ME" }
$orouter= if ($env:OPENROUTER_API_KEY) { $env:OPENROUTER_API_KEY } else { "REPLACE_ME" }
$ddKey  = if ($env:DATADOG_API_KEY)    { $env:DATADOG_API_KEY }    else { "REPLACE_ME" }

Invoke-Node @(
    "k3s kubectl create namespace greencity --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl create namespace observability --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl create namespace datadog --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n greencity create secret generic db-secret --from-literal=password='$dbPass' --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic splunk-secret --from-literal=password=Splunk_2026! --from-literal=hec-token=11111111-2222-3333-4444-555555555555 --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic grafana-secret --from-literal=admin-password=Grafana_2026! --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic sonar-db-secret --from-literal=password=Sonar_2026! --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic groq-secret --from-literal=api-key=$groq --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic elevenlabs-secret --from-literal=api-key=$eleven --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic openrouter-secret --from-literal=api-key=$orouter --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n datadog create secret generic datadog-secret --from-literal=api-key=$ddKey --dry-run=client -o yaml | k3s kubectl apply -f -",
    "k3s kubectl -n observability create secret generic mcp-secret --from-literal=bearer-token=$mcpToken --from-literal=sonar-token=PLACEHOLDER --dry-run=client -o yaml | k3s kubectl apply -f -"
) | Out-Null
Info "mcp bearer token: $mcpToken"

# ---------- 4. application + autoscaling + security ----------
Step "application, HPA, runtime security"
Apply-Manifest "greencity.yaml" @{ "__ECR_REGISTRY__" = $EcrRegistry; "__RDS_ENDPOINT__" = $RdsEndpoint }
Apply-Manifest "hpa.yaml"
Apply-Manifest "falco.yaml"
Apply-Manifest "datadog.yaml"

# ---------- 5. observability ----------
Step "observability stack (Splunk, OTel, Prometheus, Grafana, SonarQube)"
Apply-Manifest "splunk.yaml"
Apply-Manifest "otel.yaml"
Apply-Manifest "otel-logs.yaml"
Apply-Manifest "prometheus-grafana.yaml"
Apply-Manifest "sonarqube.yaml"

# ---------- 6. Splunk indexes ----------
Step "Splunk: waiting for startup, creating indexes"
Invoke-Node @("k3s kubectl -n observability rollout status deploy/splunk --timeout=600s") 700 | Out-Null
$out = Invoke-Node @(
    "SP=`$(k3s kubectl -n observability get pod -l app=splunk -o jsonpath='{.items[0].metadata.name}')",
    "k3s kubectl -n observability exec `$SP -- curl -sk -u admin:Splunk_2026! https://localhost:8089/services/data/indexes -d name=otel_metrics -d datatype=metric -o /dev/null -w 'metrics=%{http_code} '",
    "k3s kubectl -n observability exec `$SP -- curl -sk -u admin:Splunk_2026! https://localhost:8089/services/data/indexes -d name=otel_logs -o /dev/null -w 'logs=%{http_code}\n'"
) 300
Info $out

# ---------- 7. SonarQube: password, CI token, quality gate ----------
Step "SonarQube: waiting for startup"
Invoke-Node @("k3s kubectl -n observability rollout status deploy/sonarqube --timeout=600s") 700 | Out-Null
$sonar = "http://${ObsIp}:30900"
for ($i = 0; $i -lt 40; $i++) {
    try { if ((Invoke-WebRequest "$sonar/api/system/status" -TimeoutSec 10 -UseBasicParsing).Content -match '"status":"UP"') { break } } catch {}
    Start-Sleep -Seconds 15
}
Info "SonarQube is UP at $sonar"

function Sonar-Post($path, $body, $cred) {
    $h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred)) }
    try { return (Invoke-WebRequest "$sonar$path" -Method Post -Headers $h -Body $body -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30 -UseBasicParsing).Content }
    catch { return $null }
}

# default admin/admin -> our password (no-op if already changed)
Sonar-Post "/api/users/change_password" "login=admin&previousPassword=admin&password=SonarAdmin_2026%21" "admin:admin" | Out-Null
$admin = "admin:SonarAdmin_2026!"
$tokJson = Sonar-Post "/api/user_tokens/generate" "name=ci-token-$(Get-Random)&type=GLOBAL_ANALYSIS_TOKEN" $admin
$sonarToken = if ($tokJson -match '"token":"([^"]+)"') { $Matches[1] } else { $null }
if (-not $sonarToken) { throw "could not create SonarQube CI token" }
Info "sonar CI token created"

# Quality gate: realistic for a pipeline without tests (no coverage condition)
Sonar-Post "/api/qualitygates/create" "name=GreenCity+way" $admin | Out-Null
$gate = $null
try {
    $gate = (Invoke-WebRequest "$sonar/api/qualitygates/show?name=GreenCity+way" -Headers @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($admin)) } -UseBasicParsing).Content | ConvertFrom-Json
} catch {}
if ($gate) {
    # drop the impossible defaults copied from "Sonar way"
    foreach ($c in $gate.conditions) {
        if ($c.metric -in @("new_coverage", "new_violations")) {
            Sonar-Post "/api/qualitygates/delete_condition" "id=$($c.id)" $admin | Out-Null
        }
        if ($c.metric -eq "new_duplicated_lines_density") {
            Sonar-Post "/api/qualitygates/update_condition" "id=$($c.id)&metric=new_duplicated_lines_density&op=GT&error=15" $admin | Out-Null
        }
    }
    foreach ($c in @("new_reliability_rating:GT:1", "new_security_rating:GT:1", "new_blocker_violations:GT:0")) {
        $m, $op, $e = $c -split ":"
        Sonar-Post "/api/qualitygates/create_condition" "gateName=GreenCity+way&metric=$m&op=$op&error=$e" $admin | Out-Null
    }
    foreach ($p in @("greencity-backcore", "greencity-backuser", "greencity-frontend")) {
        Sonar-Post "/api/qualitygates/select" "gateName=GreenCity+way&projectKey=$p" $admin | Out-Null
    }
    Info "quality gate 'GreenCity way' configured"
}

# ---------- 8. SSM params for CodeBuild ----------
Step "SSM parameters for the CI Quality Gate"
aws ssm put-parameter --region $Region --name "/greencity/sonar-host-url" --type String --value $sonar --overwrite | Out-Null
aws ssm put-parameter --region $Region --name "/greencity/sonar-token" --type SecureString --value $sonarToken --overwrite | Out-Null
Info "/greencity/sonar-host-url = $sonar"

# ---------- 9. MCP + ChatOps ----------
Step "MCP server + Hermes ChatOps"
Invoke-Node @(
    "k3s kubectl -n observability create secret generic mcp-secret --from-literal=bearer-token=$mcpToken --from-literal=sonar-token=$sonarToken --dry-run=client -o yaml | k3s kubectl apply -f -"
) | Out-Null

$mcpCode = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $manifests "mcp/server.py")))
Invoke-Node @(
    "echo '$mcpCode' | base64 -d > /tmp/mcp-server.py",
    "k3s kubectl -n observability create configmap mcp-code --from-file=server.py=/tmp/mcp-server.py --dry-run=client -o yaml | k3s kubectl apply -f -"
) | Out-Null
Apply-Manifest "mcp/mcp-server.yaml" @{ "__RDS_ENDPOINT__" = $RdsEndpoint; "__DB_SECRET_ARN__" = $DbSecretArn }

$hermesCode = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $manifests "hermes/hermes_agent.py")))
Invoke-Node @(
    "echo '$hermesCode' | base64 -d > /tmp/hermes_agent.py",
    "k3s kubectl -n observability create configmap hermes-code --from-file=hermes_agent.py=/tmp/hermes_agent.py --dry-run=client -o yaml | k3s kubectl apply -f -"
) | Out-Null
Apply-Manifest "hermes/hermes-agent.yaml"

# ---------- 10. build images ----------
if (-not $SkipBuild) {
    Step "CodeBuild: building images (CI + CCI + SCA)"
    $bid = aws codebuild start-build --region $Region --project-name greencity-build --query "build.id" --output text
    Info "build started: $bid  (~12 min; watch it or check Discord)"
}

# ---------- summary ----------
Step "DONE"
@"
Splunk      http://${ObsIp}:30800   admin / Splunk_2026!
Grafana     http://${ObsIp}:30300   admin / Grafana_2026!
SonarQube   http://${ObsIp}:30900   admin / SonarAdmin_2026!
MCP server  http://${ObsIp}:30880/mcp   Bearer $mcpToken
ChatOps     http://${ObsIp}:30890
App (ALB)   $($tf.frontend_url.value)
Jenkins     $($tf.jenkins_url.value)

Windows voice agent: set GREENCITY_BACKEND=http://${ObsIp}:30890 in windows-agent\.env
Point the Cloudflare CNAME at the ALB above if the DNS name changed.
"@ | Write-Host -ForegroundColor Green
