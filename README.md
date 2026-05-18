# Task Tracker — DevOps Take-Home

A FastAPI Task Tracker service, containerized, provisioned on AWS with Terraform,
shipped through GitHub Actions to Amazon ECR, and deployed on Amazon ECS (Fargate)
behind an Application Load Balancer, with DNS managed via Route 53 and monitored
with Prometheus + Grafana + Node Exporter.

---

## Architecture

```
              ┌─────────────────────────────────────────────────────────────┐
              │                       Developer                              │
              └───────────────┬─────────────────────────────────────────────┘
                              │
                    ┌─────────┴──────────┐
                    │  git push tag v*   │   git push main
                    ▼                    ▼
       ┌────────────────────┐   ┌────────────────────────┐
       │  ecr-docker-push   │   │    deploy-prod         │
       │  (build & push     │   │  (workflow_dispatch)   │
       │   image to ECR)    │   │  updates ECS service   │
       └────────┬───────────┘   └──────────┬─────────────┘
                │                          │
                ▼                          ▼
       ┌─────────────────┐       ┌─────────────────────┐
       │  Amazon ECR     │──────▶│  Amazon ECS (Fargate)│
       │  (Docker image  │       │  Task: zocket        │
       │   registry)     │       │  Service: zocket-svc │
       └─────────────────┘       └──────────┬──────────┘
                                            │
                                            ▼
                                 ┌─────────────────────┐
                                 │  Application Load   │
                                 │  Balancer (ALB)     │
                                 └──────────┬──────────┘
                                            │
                                            ▼
                                 ┌─────────────────────┐
                                 │  Route 53           │
                                 │  (DNS → ALB)        │
                                 └─────────────────────┘
```

---

## Repository layout

```
.
├── app/                       # FastAPI source + tests
│   ├── main.py                # POST /tasks, GET /tasks, /healthz, /metrics
│   ├── database.py models.py schemas.py
│   ├── requirements.txt requirements-dev.txt
│   └── tests/                 # pytest
├── Dockerfile                 # multi-stage: base → test → runtime
├── docker-compose.yml         # local: app + node-exporter + prometheus + grafana
├── terraform/                 # EC2, SG, S3, IAM, key pair, inventory generator
├── ansible/                   # playbook to install docker + run container
├── monitoring/                # prometheus.yml + grafana provisioning + dashboard
├── .github/workflows/
│   ├── ecr-docker-push.yml    # triggered on git tag v* → builds & pushes to ECR
│   └── deploy-prod.yml        # manual trigger → updates ECS task + service
```

---

## Prerequisites

- Docker Desktop (or any Docker engine) — used for local runs, building, and tests.
- AWS account + credentials (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).
- Amazon ECR repository created.
- Amazon ECS cluster + service + task definition created.
- Application Load Balancer wired to the ECS target group.

---

## 1. Run locally

```bash
docker compose up --build app
curl -s http://localhost:3000/healthz
curl -s -X POST http://localhost:3000/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"hello","description":"world","status":"pending"}'
curl -s http://localhost:3000/tasks
curl -s http://localhost:3000/metrics | head
```

To bring up the full local stack (app + Prometheus + Grafana + node_exporter):

```bash
docker compose up -d
# Grafana → http://localhost:3001  (admin / admin)
# Prometheus → http://localhost:9090
```

Run the test suite without any local Python install:

```bash
docker build --target test -t task-tracker-api:test .
```

---

## 2. Provision infrastructure (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars

alias tf='docker run --rm -it -v "$PWD:/tf" -w /tf \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
    -e AWS_REGION hashicorp/terraform:1.9'

tf init
tf plan -out tfplan
tf apply tfplan
```

---

## 3. CI/CD

### Workflow 1 — Build & Push to ECR (`ecr-docker-push.yml`)

Triggered on any tag matching `v*` (e.g. `git tag v1.0.0 && git push origin v1.0.0`):

1. Checks out code
2. Extracts image tag from the Git tag
3. Authenticates with AWS + logs into ECR
4. Builds Docker image, tags as `<version>` and `latest`, pushes both to ECR

### Workflow 2 — Deploy to ECS (`deploy-prod.yml`)

Triggered manually via `workflow_dispatch` (Actions → Deploy Zocket to PROD → Run workflow):

1. Fetches current ECS task definition
2. Updates the container image to the specified version
3. Registers a new task definition revision
4. Updates the ECS service with `--force-new-deployment`
5. Waits for the service to stabilise

### Required GitHub Secrets

| Secret                  | Value                                  |
| ----------------------- | -------------------------------------- |
| `AWS_ACCESS_KEY_ID`     | IAM user access key                    |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key                    |
| `AWS_REGION`            | e.g. `ap-south-1`                      |
| `ECR_REGISTRY`          | e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com` |
| `ECR_REPOSITORY`        | ECR repository name                    |
| `ECS_CLUSTER`           | ECS cluster name                       |
| `ECS_SERVICE`           | ECS service name                       |
| `ECS_TASK`              | ECS task definition family name        |

---

## 4. API reference

Base URL: `http://zocket-alb-690003003.ap-south-1.elb.amazonaws.com`

| Method | Path       | Body                                                                        | Notes               |
| ------ | ---------- | --------------------------------------------------------------------------- | ------------------- |
| `POST` | `/tasks`   | `{"title": "...", "description": "...", "status": "pending\|in_progress\|done"}` | 201 returns the row |
| `GET`  | `/tasks`   | —                                                                           | newest first        |
| `GET`  | `/healthz` | —                                                                           | liveness probe      |
| `GET`  | `/metrics` | —                                                                           | Prometheus metrics  |

### Smoke tests

```bash
ALB=http://zocket-alb-690003003.ap-south-1.elb.amazonaws.com

# Health check
curl $ALB/healthz

# Create a task
curl -X POST $ALB/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"first","description":"test","status":"pending"}'

# List all tasks
curl $ALB/tasks
```

---

## 5. Monitoring

- **App metrics** — `prometheus-fastapi-instrumentator` exposes `/metrics` on the app itself.
- **Host metrics** — Node Exporter on `:9100`.
- **Prometheus + Grafana** — run the optional containers in `docker-compose.yml`. The Grafana dashboard `Task Tracker` is auto-provisioned with RPS, p95 latency, CPU%, and memory panels.

```bash
docker compose up -d prometheus grafana
# Grafana → http://localhost:3001  (admin / admin)
# Prometheus → http://localhost:9090
```

---

## 6. Tear down

```bash
cd terraform && tf destroy
```

---

## Design decisions

| Decision                                    | Why                                                                         |
| ------------------------------------------- | --------------------------------------------------------------------------- |
| **FastAPI**                                 | Tiny surface, async-ready, has a Prometheus instrumentor on a shelf         |
| **SQLite on a Docker volume**               | Zero extra infra; assignment says SQLite *or* Postgres                      |
| **Multi-stage Dockerfile w/ test stage**    | The CI test job is `docker build --target test` — same exact env as runtime |
| **Amazon ECR**                              | Native AWS registry, no extra credentials beyond IAM                        |
| **Amazon ECS (Fargate)**                    | Serverless container hosting — no EC2 instances to manage                   |
| **ALB in front of ECS**                     | Health checks, rolling deployments, host-based routing                      |
| **Route 53 CNAME → ALB**                   | Clean DNS routing without hardcoding IPs                                    |
| **Tag-triggered ECR push**                  | Decouples image build from deployment; every tag is an immutable artifact    |
| **`workflow_dispatch` deploy**              | Explicit, auditable production deploys with version selection               |
| **`docker compose` for monitoring stack**   | Keeps it optional and trivially reproducible locally                        |

## Challenges / trade-offs

- **State** — SQLite means data lives in the container's ephemeral volume. For production, switch to RDS and remove the volume mount.
- **TLS** — ALB listens on port 80. Next step: attach an ACM certificate and add an HTTPS listener.
- **Remote Terraform state** — kept local for simplicity; an S3 backend block is one paragraph away.
- **Public DNS** — Route 53 hosted zone is configured; public resolution requires registering the domain and delegating nameservers.

## Bonus checklist

- [x] Zero-downtime deploy (ECS rolling update + ALB health checks)
- [x] Self-healing (ECS restarts failed tasks automatically)
- [x] ECS/Fargate deployment
- [x] Container registry (Amazon ECR)
- [x] DNS routing (Route 53 → ALB)
