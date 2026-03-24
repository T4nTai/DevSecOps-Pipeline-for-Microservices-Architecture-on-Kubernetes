## Cấu trúc thư mục

```bash
devsecops-thesis/
│
├── app/                        # Application layer
│   ├── src/
│   ├── tests/
│   ├── package.json
│   ├── Dockerfile
│   └── Jenkinsfile
│
├── cicd/                       # CI scripts (decouple khỏi Jenkinsfile)
│   ├── scripts/
│   │   ├── build.sh
│   │   ├── test.sh
│   │   ├── scan.sh
│   │   ├── docker.sh
│   │   └── update-gitops.sh
│   └── sonar-project.properties
│
├── infrastructure/             # IaC layer
│   ├── terraform/
│   │   ├── modules/
│   │   │   ├── network/
│   │   │   ├── k8s/
│   │   │   └── vm/
│   │   ├── envs/
│   │   │   ├── dev/
│   │   │   ├── staging/
│   │   │   └── prod/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── ansible/
│       ├── roles/
│       │   ├── docker/
│       │   ├── jenkins/
│       │   └── tools/
│       └── playbook.yml
│
├── gitops/                     # 🔥 CORE GitOps layer
│   ├── apps/
│   │   └── my-app/
│   │       ├── base/
│   │       │   ├── deployment.yaml
│   │       │   ├── service.yaml
│   │       │   └── ingress.yaml
│   │       │
│   │       └── overlays/
│   │           ├── dev/
│   │           │   ├── kustomization.yaml
│   │           ├── staging/
│   │           └── prod/
│   │
│   └── argocd/
│       └── application.yaml
│
├── security/                   # DevSecOps layer
│   ├── sast/                   # SonarQube config
│   ├── iac/                    # Checkov
│   ├── container/              # Trivy
│   └── secrets/                # Vault config
│
├── observability/              # Monitoring layer
│   ├── prometheus/
│   │   └── prometheus.yaml
│   ├── grafana/
│   │   └── dashboards/
│   ├── loki/
│   │   └── loki.yaml
│   └── alertmanager/
│       └── alert.yaml
│
├── docs/                       # Thesis support
│   ├── architecture.png
│   ├── workflow.md
│   ├── design-decisions.md
│   └── thesis-outline.md
│
├── scripts/
│   ├── setup.sh
│   └── teardown.sh
│
├── .env.example
├── .gitignore
└── README.md
```
"# NT114" 
