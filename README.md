# DevSecOps Pipeline for Microservices on Kubernetes

A production-style DevSecOps pipeline built on self-managed Kubernetes (Kubespray) on AWS EC2. Covers the full lifecycle from code commit to deployment — with security scanning, secrets management, GitOps, canary releases, and observability.

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
                    │    ArgoCD     │  (GitOps — watches k8s/apps/)
                    └───────┬───────┘
                            │ sync
                            ▼
┌───────────────────────────────────────────────────────────────┐
│               Kubernetes Cluster (Kubespray on AWS)           │
│                                                               │
│   Argo Rollouts ──► Canary (20%) → Stable (80%)              │
│   Nginx Ingress ──► app.tools.votantai.me                     │
│                                                               │
│   Vault (secrets)   SonarQube (SAST)   Harbor (registry)     │
│   Prometheus        Grafana            Loki (logs)            │
│   Burst Autoscaler (EC2 start/stop via CronJob)               │
└───────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Tool | Role |
|-------|------|------|
| Infrastructure | Terraform + AWS EC2 | VPC, nodes, IAM, security groups |
| Kubernetes | Kubespray | Self-managed cluster on EC2 |
| CI/CD | Jenkins | Build, test, scan, push |
| GitOps | ArgoCD | Sync manifests → cluster |
| Canary Deployment | Argo Rollouts | Traffic split 20% → 50% → 80% → 100% |
| Secrets | HashiCorp Vault | All credentials via AppRole, KMS auto-unseal |
| Container Registry | Harbor | Self-hosted image registry |
| SAST | SonarQube | Static code analysis + quality gate |
| IaC Scan | Checkov | Terraform security checks |
| Image Scan | Trivy | CVE scan before push |
| Image Build | Kaniko | In-cluster Docker builds (no daemon) |
| Ingress | Nginx | Route traffic + canary weight annotations |
| Monitoring | Prometheus + Grafana | Metrics and dashboards |
| Logging | Loki + Promtail | Log aggregation |
| Autoscaler | Custom CronJob | Start/stop EC2 burst worker on demand |

---

## CI/CD Pipeline

Each commit to `main` triggers the full pipeline:

```
1. Checkout          Clone repo
2. Unit Tests        go test ./...          ┐ parallel
3. Checkov           IaC scan on terraform/ ┘
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
| Burst Worker | t3.medium | Stopped by default, auto-started when pods are pending |

Services exposed via **Nginx Ingress** at `*.tools.votantai.me`:

| Service | URL |
|---------|-----|
| App (frontend) | `app.tools.votantai.me` |
| Jenkins | `jenkins.tools.votantai.me` |
| ArgoCD | `argocd.tools.votantai.me` |
| Harbor | `harbor.tools.votantai.me` |
| SonarQube | `sonarqube.tools.votantai.me` |
| Grafana | `grafana.tools.votantai.me` |
| Argo Rollouts | `rollouts.tools.votantai.me` |

---

## Quick Start

### 1. Provision Infrastructure

```bash
cd terraform
terraform init
terraform workspace new tools
terraform apply -var-file=terraform-tools.tfvars
```

### 2. Install Kubernetes

```bash
bash scripts/steps/01-kubespray.sh
```

### 3. Deploy All Tools

```bash
# Run steps sequentially
for step in scripts/steps/0*.sh scripts/steps/1*.sh; do
  bash "$step"
done
```

Or individually:
```bash
bash scripts/steps/05-vault.sh
bash scripts/steps/06-harbor.sh
bash scripts/steps/07-sonarqube.sh
bash scripts/steps/08-jenkins.sh
bash scripts/steps/09-argocd.sh
bash scripts/steps/10-monitoring.sh
bash scripts/steps/14-burst-autoscaler.sh
bash scripts/steps/15-argo-rollouts.sh
```

### 4. Configure & Run

- Vault: `bash k8s/vault/setup-vault.sh` — init, AppRole, store secrets
- Jenkins: create pipeline job → SCM → `jenkins/Jenkinsfile`
- ArgoCD: `kubectl apply -f k8s/argocd/apps/frontend-app.yaml`
- Trigger first build → ArgoCD syncs → canary rollout starts

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
├── terraform/          # AWS infrastructure (VPC, EC2, IAM, NLB)
├── k8s/
│   ├── apps/           # Application manifests (ArgoCD source of truth)
│   │   └── frontend/   # Rollout, Services, Ingress
│   ├── jenkins/        # Jenkins Helm values, RBAC, Ingress
│   ├── vault/          # Vault Helm values, setup script
│   ├── harbor/         # Harbor Helm values
│   ├── sonarqube/      # SonarQube manifests
│   ├── argocd/         # ArgoCD Application manifests
│   ├── argo-rollouts/  # Argo Rollouts Helm values
│   ├── monitoring/     # Prometheus, Grafana, Loki values
│   └── burst-autoscaler/ # CronJob + RBAC + ConfigMap
├── jenkins/
│   └── Jenkinsfile     # Pipeline definition
├── app/src/frontend/   # Go frontend source code + Dockerfile
└── scripts/
    └── steps/          # Step-by-step deploy scripts (01–15)
```
