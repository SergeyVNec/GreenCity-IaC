# GreenCity — Architecture

Full diagram of the platform. GitHub renders the Mermaid block below inline.

```mermaid
flowchart TB
    GH["GitHub - 3 repos<br/>backcore / backuser / frontend"]

    subgraph CICD["CI / CD pipeline"]
        direction LR
        JEN["Jenkins<br/>pollSCM ~1 min, orchestrate, notify Discord"]
        CB["AWS CodeBuild<br/>build + CCI SonarQube + SCA Trivy + Quality Gate"]
        ECR["ECR<br/>scan-on-push, lifecycle"]
        JEN --> CB --> ECR
    end

    GH -->|"no webhook rights: poll"| JEN
    ECR -->|"images :latest<br/>Gate FAIL = no deploy"| K3S

    subgraph K3S["k3s cluster - 4 EC2 nodes (1 control-plane + 2 agents + 1 observability node), Traefik ingress"]
        direction TB
        subgraph APP["Application - ns greencity"]
            A1["backcore :8080"]
            A2["backuser :8060"]
            A3["frontend x2 :80<br/>nginx same-origin proxy"]
            A4["rabbitmq :5672"]
        end
        subgraph SEC["Security and scaling"]
            S1["Pod Security Standards"]
            S2["SecurityContext + seccomp"]
            S3["Falco - runtime eBPF"]
            S4["HPA 1-3 / 2-4 on CPU"]
        end
        subgraph OBS["Observability"]
            O1["Splunk :30800"]
            O2["Grafana :30300"]
            O3["Prometheus"]
            O4["OpenTelemetry - metrics + logs"]
            O5["Datadog + SonarQube"]
        end
        subgraph OPS["AI ChatOps"]
            M1["MCP server :30880<br/>13 tools, bearer auth"]
            M2["Hermes agent :30890<br/>gpt-4o-mini + MCP"]
        end
    end

    subgraph AWS["AWS foundation - Terraform managed"]
        direction LR
        RDS["RDS PostgreSQL<br/>password to Secrets Manager"]
        ALB["ALB<br/>80 / 8080 / 8060"]
        CW["CloudWatch<br/>alarms + dashboard"]
        SEC2["Secrets Manager<br/>+ SSM Parameter Store"]
        IAM["IAM<br/>least-privilege"]
        VPC["VPC<br/>2 subnets, IGW"]
    end

    VOICE["Windows voice agent<br/>Whisper Groq -> gpt-4o-mini+MCP -> ElevenLabs<br/>wake word, no keys on client"] --> M2

    K3S === AWS

    classDef src fill:#e2e8f0,stroke:#64748b,color:#1e293b;
    classDef ci fill:#dbeafe,stroke:#2563eb,color:#1e3a8a;
    classDef reg fill:#cffafe,stroke:#0e9aa7,color:#155e63;
    classDef app fill:#dcfce7,stroke:#16a34a,color:#14532d;
    classDef sec fill:#fee2e2,stroke:#dc2626,color:#7f1d1d;
    classDef obs fill:#ede9fe,stroke:#7c3aed,color:#4c1d95;
    classDef ops fill:#fef3c7,stroke:#d97706,color:#78350f;
    classDef aws fill:#f1f5f9,stroke:#475569,color:#334155;

    class GH src;
    class JEN,CB ci;
    class ECR reg;
    class A1,A2,A3,A4 app;
    class S1,S2,S3,S4 sec;
    class O1,O2,O3,O4,O5 obs;
    class M1,M2,VOICE ops;
    class RDS,ALB,CW,SEC2,IAM,VPC aws;
```

## How it flows

1. **Source → CI:** programmers push to GitHub. We have no webhook rights, so **Jenkins polls**
   the repos (`pollSCM`) and triggers **CodeBuild**.
2. **Build & gate:** CodeBuild builds the three images and runs **SonarQube (CCI)** + **Trivy
   (SCA)**. A blocking **Quality Gate** stops the pipeline on new bugs/vulnerabilities — a failed
   gate means **no deploy**.
3. **Registry → deploy:** images land in **ECR** (scanned on push); k3s pulls `:latest`.
4. **Cluster:** the app runs in namespace `greencity`, guarded by **PSS + SecurityContext + Falco**
   and scaled by **HPA**. Six observability tools and the **MCP + Hermes ChatOps** stack run on a
   dedicated 8 GB node.
5. **Foundation:** everything sits on Terraform-managed AWS — **VPC, RDS (password in Secrets
   Manager), ALB, CloudWatch, IAM, SSM**.
6. **Voice:** a Windows tray assistant turns speech into cluster operations
   (**Whisper → gpt-4o-mini + MCP tools → ElevenLabs**).

See [README.md](README.md) for the component detail and [DECISIONS.md](DECISIONS.md) for the
"why" behind every choice.
