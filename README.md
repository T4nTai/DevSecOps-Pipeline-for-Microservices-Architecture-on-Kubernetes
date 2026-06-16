# DevSecOps Pipeline for Microservices on Kubernetes

A production-grade DevSecOps platform running [Google's Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) microservices on a self-managed Kubernetes cluster (Kubespray), with a full CI/CD pipeline, GitOps delivery, multi-layer security scanning, canary deployments, and observability stack — deployable on **AWS or Azure**.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Developer Workflow                                │
│                                                                             │
│   git push (feature)          git push (develop / main)                    │
│         │                              │                                   │
│         ▼                              ▼                                   │
│   ┌───────────┐              ┌──────────────────┐                          │
│   │ PR checks │              │  Full CI Pipeline │                         │
│   │ - Tests   │              │  (Jenkins)        │                         │
│   │ - SAST    │              └────────┬─────────┘                          │
│   │ - IaC scan│                       │                                    │
│   └───────────┘         ┌─────────────┼──────────────┐                    │
│                          │             │              │                    │
│                    Build Image    Security Scan   Unit Tests               │
│                    (Kaniko)       ┌────┴────┐                              │
│                          │        │Checkov  │                              │
│                          │        │SonarQube│                              │
│                          │        │Trivy    │                              │
│                          │        └─────────┘                              │
│                          │                                                 │
│                    Push to Harbor                                          │
│                          │                                                 │
│                    Update k8s/helm/values/<service>.yaml  (Git commit)     │
└──────────────────────────┼──────────────────────────────────────────────── ┘
                           │  GitOps (ArgoCD watches repo)
                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster (Kubespray)                      │
│                                                                             │
│  ┌────────────────────┐    ┌────────────────────┐                          │
│  │  namespace:        │    │  namespace:         │                         │
│  │  boutique-dev      │    │  boutique-prod      │                         │
│  │  (develop branch)  │    │  (main branch)      │                         │
│  │                    │    │                     │                         │
│  │  Deployment        │    │  Argo Rollout       │                         │
│  │  (fast feedback)   │    │  (canary strategy)  │                         │
│  └────────────────────┘    └────────────────────┘                          │
│                                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │  ArgoCD     │  │  Jenkins    │  │  Harbor  │  │  Prometheus + Grafana│ │
│  │  (GitOps)   │  │  (CI)       │  │(Registry)│  │  Loki + Promtail     │ │
│  └─────────────┘  └─────────────┘  └──────────┘  └──────────────────────┘ │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────┐  ┌──────────────────────┐ │
│  │  SonarQube  │  │  Vault      │  │cert-mgr  │  │  Argo Rollouts       │ │
│  │  (SAST)     │  │  (Secrets)  │  │(TLS/ACME)│  │  (canary dashboard)  │ │
│  └─────────────┘  └─────────────┘  └──────────┘  └──────────────────────┘ │
│                                                                             │
│  Cloud: AWS (EC2 + NLB + Route53 + KMS) │ Azure (VM + LB + Key Vault)     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| **Infrastructure** | Terraform (modular), Kubespray |
| **Cloud** | AWS (EC2, NLB, Route53, KMS, S3) / Azure (VM, LB, Key Vault) |
| **Container Orchestration** | Kubernetes (self-managed, HA-ready) |
| **CI** | Jenkins (Shared Library), Kaniko, crane |
| **GitOps / CD** | ArgoCD, ArgoCD ApplicationSet |
| **Progressive Delivery** | Argo Rollouts (canary + nginx traffic split) |
| **Package Management** | Helm, Helmfile (layered: base → overlay → env) |
| **Container Registry** | Harbor |
| **Secrets** | HashiCorp Vault (KMS auto-unseal, AppRole auth) |
| **SAST** | SonarQube |
| **Image Scanning** | Trivy |
| **IaC Scanning** | Checkov |
| **TLS** | cert-manager + Let's Encrypt (DNS-01 / Route53 or Azure DNS) |
| **Ingress** | ingress-nginx |
| **Monitoring** | Prometheus, Grafana, kube-prometheus-stack |
| **Logging** | Loki, Promtail |
| **Network Security** | Kubernetes NetworkPolicy (default-deny) |
| **Application** | Google Online Boutique (12 microservices, Go/Python/Java/Node/.NET) |

---

## Repository Structure

```
.
├── app/src/                        # Microservice source code + Jenkinsfiles
│   ├── frontend/Jenkinsfile
│   ├── cartservice/Jenkinsfile
│   └── ...
├── infra/
│   ├── aws/
│   │   ├── bootstrap/              # S3 + DynamoDB for Terraform state
│   │   ├── envs/tools/             # Root module: provisions entire cluster
│   │   └── modules/                # vpc, compute, iam, nlb, ingress-nlb, route53, security
│   └── azure/
│       ├── envs/tools/
│       └── modules/                # network, compute, identity, loadbalancer, keyvault
├── platform/kubespray/             # Kubespray inventory + run script
├── tools/
│   ├── base/helmfile.yaml          # Cloud-agnostic Helm releases
│   ├── base/values/                # Default values for all tools
│   ├── overlays/aws/               # AWS-specific overrides (storageClass, LB type, KMS)
│   ├── overlays/azure/             # Azure-specific overrides
│   ├── envs/{dev,prod}/            # Per-environment overrides
│   └── ingresses/                  # Ingress manifests for tools (ArgoCD, Jenkins, SonarQube)
├── k8s/
│   ├── argocd/apps/                # ApplicationSets (dev + prod)
│   ├── helm/microservice/          # Generic Helm chart for all microservices
│   ├── helm/values/                # Per-service values (image tag updated by CI)
│   ├── network-policies/           # Default-deny + granular allow rules
│   └── jenkins/rbac.yaml           # Jenkins ServiceAccount + ClusterRole
├── jenkins/shared-library/         # Shared Library: devsecOpsPipeline()
├── scripts/
│   ├── deploy.sh                   # Orchestrates full deployment (steps 0–13)
│   └── lib/                        # Modular step scripts (terraform, kubespray, dns, ...)
└── connect.sh                      # SSH tunnel to bastion (kubectl proxy)
```

---

## CI/CD Pipeline

Every microservice uses the same `devsecOpsPipeline()` call — no duplicated pipeline code.

```groovy
// app/src/frontend/Jenkinsfile
@Library('devsecops-shared-lib@main') _

devsecOpsPipeline(
    appDir:    'app/src/frontend',
    imageName: 'frontend',
    language:  'golang'
)
```

### Pipeline Stages

```
PR (any branch)                       Merge to develop / main
─────────────────                     ──────────────────────────────────────────
✓ Load Secrets (Vault AppRole)        ✓ Load Secrets (Vault AppRole)
✓ Checkout + [skip ci] guard          ✓ Checkout + [skip ci] guard
✓ Unit Tests                          ✓ Build Image (Kaniko, rootless, --no-push)
✓ SonarQube SAST                      ✓ Unit Tests
✓ Checkov IaC scan                    ✓ Security Scan (parallel):
                                          - Checkov (IaC)
                                          - SonarQube (SAST + Quality Gate)
                                          - Trivy (image scan from .tar)
                                          - Trivy (k8s/helm/ manifests)
                                      ✓ Push to Harbor (crane)
                                      ✓ Update k8s/helm/values/<service>.yaml
                                      ✓ Git push [skip ci] → triggers ArgoCD sync
```

**Branch → environment mapping:**

| Branch | Image tag | ArgoCD target | Namespace |
|---|---|---|---|
| `develop` | `dev-<N>` | `online-boutique-dev` | `boutique-dev` |
| `main` | `<N>` | `online-boutique-prod` | `boutique-prod` |

---

## Canary Deployment (prod)

Production deployments use Argo Rollouts with canary traffic splitting via ingress-nginx:

```yaml
# Enabled per-service in k8s/helm/values/<service>.yaml
canary:
  enabled: true
  steps:
    - setWeight: 20
    - pause: { duration: 2m }
    - setWeight: 50
    - pause: { duration: 2m }
    - setWeight: 100
  trafficRouting:
    enabled: true
```

---

## Getting Started

### Prerequisites

| Tool | Version |
|---|---|
| Terraform | >= 1.3 |
| Ansible / Kubespray | 2.24+ |
| kubectl | >= 1.29 |
| helm | >= 3.14 |
| helmfile | >= 0.162 |
| AWS CLI / Azure CLI | latest |
| `jq`, `envsubst` | any |

### 1. Bootstrap Terraform state (AWS only, one-time)

```bash
cd infra/aws/bootstrap
terraform init && terraform apply
```

### 2. Configure secrets

```bash
cp .env.example .env.secret
# Fill in: DOMAIN, passwords, AWS_REGION, VAULT_KMS_KEY_ARN, etc.
set -a; source .env.secret; set +a
```

### 3. Provision infrastructure

**AWS:**
```bash
cd infra/aws/envs/tools
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: allowed_ssh_cidr, domain_name, vault_kms_key_arn
terraform init && terraform apply
```

**Azure:**
```bash
cd infra/azure/envs/tools
cp backend.conf.example backend.conf
# Edit terraform.tfvars
terraform init -backend-config=backend.conf && terraform apply
```

### 4. Provision Kubernetes with Kubespray

```bash
bash platform/kubespray/generate-inventory.sh   # reads Terraform outputs
bash platform/kubespray/run-kubespray.sh
```

### 5. Open SSH tunnel

```bash
./connect.sh --cloud=aws --cluster=tools
export KUBECONFIG=.kubeconfig
kubectl get nodes   # all nodes should be Ready
```

### 6. Deploy the full platform

```bash
bash scripts/deploy.sh
```

This runs steps in order: DNS fix → autoscaler → monitoring → ingress → ArgoCD → Jenkins → cert-manager → SonarQube → Harbor → Vault → Argo Rollouts → ApplicationSets.

### 7. Apply Helmfile (alternative / manual)

```bash
# AWS dev environment
helmfile -f tools/overlays/aws/helmfile.yaml \
         --state-values-file tools/envs/dev/values.yaml sync
```

---

## Service Endpoints

After deployment, services are available at:

| Service | URL |
|---|---|
| App (dev) | `https://app-dev.<DOMAIN>` |
| App (prod) | `https://app.<DOMAIN>` |
| ArgoCD | `https://argocd.<DOMAIN>` |
| Jenkins | `https://jenkins.<DOMAIN>` |
| Grafana | `https://grafana.<DOMAIN>` |
| SonarQube | `https://sonarqube.<DOMAIN>` |
| Harbor | `https://harbor.<DOMAIN>` |
| Vault | `https://vault.<DOMAIN>` |
| Argo Rollouts | `https://rollouts.<DOMAIN>` |

All services use a wildcard TLS certificate issued by Let's Encrypt via DNS-01 challenge.

---

## Security Design

- **Network**: Default-deny NetworkPolicy in boutique namespaces; explicit allow rules for DNS, ingress, and monitoring scrape
- **Secrets**: All pipeline secrets (Git token, Harbor credentials, SonarQube token) fetched from Vault at runtime via AppRole — nothing stored in Jenkins
- **Images**: Built with Kaniko (no Docker daemon, no root); scanned with Trivy before push
- **IaC**: Scanned with Checkov on every PR and branch build
- **Code**: SonarQube SAST with Quality Gate enforcement — pipeline fails if gate is not passed
- **IAM**: Separate instance profiles for stateful workers (Vault KMS access) vs. general workers
- **TLS**: Wildcard cert via cert-manager + Let's Encrypt DNS-01; auto-renewed

---

## Application Workload

The application layer uses [Google's Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) — a polyglot e-commerce demo (Go, Python, Java, C#, Node.js) — as a realistic workload to exercise the pipeline across multiple languages and runtimes.

The focus of this project is the **platform and pipeline**, not the application code. Online Boutique is treated as a black-box workload: source code is unchanged, Dockerfiles are reused as-is, and the Shared Library handles all CI logic generically via the `language` parameter.
