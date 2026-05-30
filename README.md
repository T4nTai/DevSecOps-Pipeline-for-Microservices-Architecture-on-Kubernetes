# DevSecOps Pipeline for Microservices on Kubernetes

A production-style DevSecOps pipeline built on self-managed Kubernetes (Kubespray) on AWS EC2 or Azure VMs. Covers the full lifecycle from infrastructure provisioning to canary deployment — with security scanning, secrets management, GitOps, and observability.

**Multi-cloud:** AWS (EC2 + NLB + Route53 + KMS) and Azure (VMs + Load Balancer + Key Vault).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Developer                                │
└───────────────────────────┬─────────────────────────────────────┘
                            │ git push
                            ▼
                    ┌───────────────┐
                    │    GitHub     │
                    └───────┬───────┘
                            │ webhook trigger
                            ▼
┌───────────────────────────────────────────────────────────────┐
│                      Jenkins CI                               │
│                                                               │
│  Unit Tests ─► Checkov (IaC) ─► Build ─► SonarQube (SAST)   │
│                                    │                          │
│                              Kaniko Build                     │
│                                    │                          │
│                            Trivy (image scan)                 │
│                                    │                          │
│                          Push to Harbor ──────────────────►  Harbor Registry
│                                    │                          │
│                       Update rollout.yaml                     │
└───────────────────────────┬───────────────────────────────────┘
                            │ git push (manifest)
                            ▼
                    ┌───────────────┐
                    │    ArgoCD     │  (GitOps — watches k8s/helm/ via ApplicationSet)
                    └───────┬───────┘
                            │ sync
                            ▼
┌───────────────────────────────────────────────────────────────┐
│           Kubernetes Cluster (Kubespray on AWS / Azure)       │
│                                                               │
│   Argo Rollouts ──► Canary (20%) → Stable (80%)              │
│   Nginx Ingress ──► app.DOMAIN                                │
│                                                               │
│   Vault (secrets)   SonarQube (SAST)   Harbor (registry)     │
│   Prometheus        Grafana            Loki (logs)            │
└───────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Tool | Role |
|-------|------|------|
| Infrastructure | Terraform + AWS EC2 / Azure VMs | VPC/VNet, nodes, IAM, security groups |
| Kubernetes | Kubespray | Self-managed cluster on EC2 / Azure VMs |
| Tools Deployment | Helmfile | Declarative multi-release deployment with base/overlay pattern |
| CI/CD | Jenkins | Build, test, scan, push |
| GitOps | ArgoCD | Sync manifests → cluster via ApplicationSet |
| Canary Deployment | Argo Rollouts | Traffic split 20% → 50% → 80% → 100% |
| Secrets | HashiCorp Vault | All credentials via AppRole, KMS/Key Vault auto-unseal |
| Container Registry | Harbor | Self-hosted image registry |
| SAST | SonarQube | Static code analysis + quality gate |
| IaC Scan | Checkov | Terraform security checks |
| Image Scan | Trivy | CVE scan before push |
| Image Build | Kaniko | In-cluster Docker builds (no daemon) |
| Ingress | Nginx | Route traffic + canary weight annotations |
| Monitoring | Prometheus + Grafana | Metrics and dashboards |
| Logging | Loki + Promtail | Log aggregation |

---

## Prerequisites

Install these tools locally before deploying:

```bash
# Required
terraform   >= 1.3
ansible     >= 8.0       # for Kubespray
kubectl     >= 1.28
helm        >= 3.14
helmfile    >= 0.162
aws         CLI v2       # AWS only
az          CLI          # Azure only

# Optional but recommended
jq
envsubst    (gettext)
```

---

## Quick Start

### 1. Clone and configure environment

```bash
git clone https://github.com/T4nTai/DevSecOps-Pipeline-for-Microservices-Architecture-on-Kubernetes.git
cd DevSecOps-Pipeline-for-Microservices-Architecture-on-Kubernetes
```

Create `.env` (committed config — no secrets):
```bash
# .env
CLOUD=aws
DOMAIN=tools.yourdomain.com
ACME_EMAIL=you@example.com
AWS_REGION=ap-southeast-1
PROJECT_NAME=devsecops
```

Create `.env.secret` (never committed — real credentials):
```bash
# .env.secret
GRAFANA_ADMIN_PASSWORD=changeme
JENKINS_ADMIN_PASSWORD=changeme
HARBOR_ADMIN_PASSWORD=changeme
SONAR_DB_PASSWORD=changeme
```

### 2. Deploy everything

```bash
# AWS
bash scripts/deploy.sh --cloud=aws

# Azure
bash scripts/deploy.sh --cloud=azure

# Resume from a specific step (e.g. after fixing cert-manager)
bash scripts/deploy.sh --cloud=aws --start-from=09
```

The script runs 13 steps in sequence:

| Step | What it does |
|------|-------------|
| 01 | Terraform — provision DNS state + cluster infrastructure |
| 02 | Kubespray — install Kubernetes on EC2 / Azure VMs |
| 03 | DNS fix — patch CoreDNS for NLB hostname resolution |
| 04 | Cluster Autoscaler |
| 05 | Prometheus + Grafana + Loki + Promtail |
| 06 | Nginx Ingress Controller |
| 07 | ArgoCD + Online Boutique ApplicationSet |
| 08 | Jenkins |
| 09 | cert-manager + TLS wildcard certificate |
| 10 | SonarQube |
| 11 | Harbor |
| 12 | Vault |
| 13 | Argo Rollouts |

### 3. DNS delegation (AWS only — first deploy)

After step 01, the script prints 4 Route53 nameservers. Set them in your domain registrar (e.g. Namecheap):

```
Domain List → Manage → Nameservers → Custom DNS
ns-XXX.awsdns-XX.com
ns-XXX.awsdns-XX.net
ns-XXX.awsdns-XX.org
ns-XXX.awsdns-XX.co.uk
```

Wait 5–30 minutes for propagation. Step 09 checks delegation before running cert-manager. If it fails, re-run:

```bash
bash scripts/deploy.sh --cloud=aws --start-from=09
```

### 4. Post-deploy setup

```bash
# Init Vault (first deploy only)
bash k8s/vault/setup-vault.sh

# Create Jenkins pipeline job
# → SCM → point to app/src/<service>/Jenkinsfile

# Trigger first build → ArgoCD syncs → canary rollout starts
```

---

## Alternative: Deploy tools with Helmfile

If the cluster is already running and you only need to update tools:

```bash
# Fill in tools/envs/dev/values.yaml with real values, then:
helmfile -f tools/overlays/aws/helmfile.yaml \
         --state-values-file tools/envs/dev/values.yaml \
         sync

# Preview changes before applying
helmfile -f tools/overlays/aws/helmfile.yaml \
         --state-values-file tools/envs/dev/values.yaml \
         diff

# Deploy a single tool
helmfile -f tools/overlays/aws/helmfile.yaml \
         --state-values-file tools/envs/dev/values.yaml \
         -l name=jenkins sync
```

---

## CI/CD Pipeline

Each commit to `main` triggers the full pipeline:

```
1. Checkout          Clone repo
2. Unit Tests        go test ./...          ┐ parallel
3. Checkov           IaC scan on infra/     ┘
4. Build             go build (binary)
5. SonarQube         SAST + quality gate (webhook → fast)
6. Kaniko            Build image in-cluster
7. Trivy             Scan image for HIGH/CRITICAL CVEs
8. Harbor Push       Push image to Harbor registry
9. Update Manifest   yq → update image tag in rollout.yaml → git push
10. ArgoCD           Detects change → triggers Argo Rollouts canary
```

---

## Canary Deployment Flow

When ArgoCD syncs the updated `rollout.yaml`:

```
New image pushed
      │
      ▼
 20% traffic → canary pods     ← pause (manual approval required)
      │
   promote
      │
      ▼
 50% traffic → 10 min wait (automatic)
      │
      ▼
 80% traffic → 5 min wait (automatic)
      │
      ▼
 100% stable (rollout complete)
```

Commands:
```bash
kubectl argo rollouts get rollout frontend -n default --watch
kubectl argo rollouts promote frontend -n default   # approve
kubectl argo rollouts abort frontend -n default     # rollback
```

---

## Infrastructure

Single Kubernetes cluster on AWS (region: `ap-southeast-1`):

| Node | Type | Role |
|------|------|------|
| Bastion | t3.micro | SSH entry point (public subnet) |
| Control Plane | t3.small | K8s control plane |
| Worker × 3 | t3.large | All workloads |

Services exposed via Nginx Ingress at `*.DOMAIN`:

| Service | URL |
|---------|-----|
| App (frontend) | `app.DOMAIN` |
| Jenkins | `jenkins.DOMAIN` |
| ArgoCD | `argocd.DOMAIN` |
| Harbor | `harbor.DOMAIN` |
| SonarQube | `sonarqube.DOMAIN` |
| Grafana | `grafana.DOMAIN` |
| Vault | `vault.DOMAIN` |
| Argo Rollouts | `rollouts.DOMAIN` |

---

## Secrets in Vault

| Path | Keys |
|------|------|
| `secret/harbor` | `registry`, `username`, `password` |
| `secret/sonarqube` | `token` |
| `secret/git` | `username`, `token` |

Jenkins fetches secrets at runtime via `withVault{}` — no credentials stored in Jenkins or manifests.

---

## Repository Structure

```
.
├── infra/
│   ├── aws/
│   │   ├── dns/                  # Route53 hosted zone (separate Terraform state)
│   │   ├── envs/tools/           # Cluster infrastructure (EC2, NLB, IAM, ASG)
│   │   └── modules/              # route53, compute, networking modules
│   └── azure/
│       └── envs/tools/           # Azure VMs, Load Balancer, Key Vault
│
├── platform/
│   └── kubespray/                # Inventory generator + Kubespray run scripts
│
├── tools/                        # Helmfile for DevSecOps tools
│   ├── base/
│   │   ├── helmfile.yaml         # 11 releases (cloud-agnostic)
│   │   └── values/               # Base values for every tool
│   ├── overlays/
│   │   ├── aws/                  # AWS overrides: NLB, IRSA, KMS, ebs-sc
│   │   └── azure/                # Azure overrides: LB, Workload Identity, Key Vault
│   ├── envs/
│   │   ├── dev/values.yaml       # Dev state values (domain, passwords, ARNs)
│   │   └── prod/values.yaml      # Prod state values
│   ├── ingresses/                # Ingress manifests (envsubst: ${DOMAIN})
│   └── issuers/                  # ClusterIssuer + Certificate (envsubst)
│
├── k8s/
│   ├── helm/                     # Helm chart template for microservices
│   ├── argocd/
│   │   └── apps/
│   │       └── online-boutique-appset.yaml   # ArgoCD ApplicationSet
│   ├── jenkins/rbac.yaml         # Jenkins RBAC
│   ├── sonarqube/                # SonarQube raw manifests (namespace, PVC, postgres)
│   └── vault/setup-vault.sh      # Vault init + AppRole setup
│
├── scripts/
│   ├── deploy.sh                 # Main entry point: bash scripts/deploy.sh --cloud=aws
│   └── lib/
│       ├── 00-checks.sh          # Helper functions (log_ok, check_state, ...)
│       ├── 01-terraform.sh       # Terraform: DNS state + cluster state
│       ├── 02-kubespray.sh       # Kubespray: install Kubernetes
│       ├── 03-dns-fix.sh         # CoreDNS patch for NLB
│       ├── 04-autoscaler.sh      # Cluster Autoscaler
│       ├── 05-monitoring.sh      # Prometheus + Grafana + Loki + Promtail
│       ├── 06-ingress.sh         # Nginx Ingress + Sorry Page
│       ├── 07-argocd.sh          # ArgoCD + ApplicationSet
│       ├── 08-jenkins.sh         # Jenkins
│       ├── 09-cert-manager.sh    # cert-manager + TLS wildcard cert
│       ├── 10-sonarqube.sh       # SonarQube
│       ├── 11-harbor.sh          # Harbor
│       ├── 12-vault.sh           # Vault
│       └── 13-argo-rollouts.sh   # Argo Rollouts
│
├── app/src/                      # Microservice source code + Dockerfiles
│   └── <service>/
│       ├── Dockerfile
│       └── Jenkinsfile
│
└── jenkins/
    └── shared-library/           # Jenkins shared pipeline library
```
