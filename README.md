# Task Tracker — DevOps Assignment

A FastAPI Task Tracker service, containerised with Docker, provisioned on AWS with
Terraform (ECS Fargate + ALB), shipped via GitHub Actions CI/CD, with host and
application metrics collected by Prometheus Node Exporter and visualised in Grafana.

---

## Architecture

```
  Developer
     │
     ├── git tag v*  ──────────────────────────────────────────────────────────┐
     │                                                                          │
     └── git push main                                                          ▼
              │                                                   ┌─────────────────────┐
              │  workflow_dispatch                                 │  GitHub Actions      │
              │  (choose version)                                  │  ecr-docker-push     │
              ▼                                                    │  builds & pushes     │
   ┌─────────────────────┐                                        │  image to ECR        │
   │  GitHub Actions      │                                        └──────────┬──────────┘
   │  deploy-prod         │                                                   │
   │  updates ECS task    │                                                   ▼
   └──────────┬──────────┘                                        ┌─────────────────────┐
              │                                                    │  Amazon ECR          │
              ▼                                                    │  (image registry)    │
   ┌─────────────────────┐                                        └──────────┬──────────┘
   │  Amazon ECS Fargate  │◀───────────────────────────────────────────────┘
   │  zocket-api container│
   └──────────┬──────────┘
              │  target port 3000
              ▼
   ┌─────────────────────┐
   │  Application Load   │
   │  Balancer (port 80) │
   └─────────────────────┘

  Monitoring (local + EC2)
  ┌──────────────────────────────────────────────────────┐
  │  Prometheus (:9090)                                   │
  │    ├── scrapes node-exporter:9100  (host metrics)    │
  │    ├── scrapes app:3000/metrics    (API metrics)     │
  │    └── scrapes localhost:9090      (self metrics)    │
  │  Grafana (:3001)                                      │
  │    ├── Task Tracker dashboard (RPS, latency, errors) │
  │    └── Node Exporter dashboard (CPU, RAM, disk, net) │
  └──────────────────────────────────────────────────────┘
```

---

## Repository layout

```
.
├── app/
│   ├── main.py                 # FastAPI app — /tasks, /healthz, /metrics
│   ├── database.py             # SQLAlchemy SQLite setup
│   ├── models.py               # Task ORM model
│   ├── schemas.py              # Pydantic schemas
│   ├── requirements.txt
│   ├── requirements-dev.txt
│   └── tests/                  # pytest suite
├── Dockerfile                  # multi-stage: base → test → runtime
├── docker-compose.yml          # app + node-exporter + prometheus + grafana
├── monitoring/
│   ├── prometheus.yml          # global config + file_sd_configs jobs
│   ├── targets/
│   │   ├── node.json           # node-exporter scrape targets (local + prod)
│   │   └── task-api.json       # task-api scrape targets (local + prod)
│   └── grafana-provisioning/
│       ├── datasources/
│       │   └── prometheus.yml  # auto-provision Prometheus datasource (uid: prometheus)
│       └── dashboards/
│           ├── dashboards.yml  # dashboard provider config
│           ├── task-tracker.json   # API metrics dashboard (6 panels)
│           └── node-exporter.json  # host metrics dashboard (10 panels)
├── terraform/                  # ECS Fargate, ALB, ECR, IAM, CloudWatch
├── ansible/                    # EC2 host provisioning — Docker + node-exporter
└── .github/workflows/
    ├── ecr-docker-push.yml     # tag v* → build & push image to ECR
    └── deploy-prod.yml         # manual → update ECS service to new image version
```

---

## Prerequisites

- Docker Desktop (macOS/Windows) or Docker Engine (Linux)
- AWS account with credentials exported:
  ```bash
  export AWS_ACCESS_KEY_ID=...
  export AWS_SECRET_ACCESS_KEY=...
  export AWS_REGION=ap-south-1
  ```
- Terraform ≥ 1.9 (or use the Docker alias below)
- Ansible ≥ 2.14 with the `community.docker` collection

---

## 1. Run the app locally

```bash
# Build and start only the API
docker compose up --build app

# Verify
curl http://localhost:3000/healthz
curl -X POST http://localhost:3000/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"buy milk","description":"skimmed","status":"pending"}'
curl http://localhost:3000/tasks
curl http://localhost:3000/metrics | head -20
```

---

## 2. Run the test suite

No local Python install required — tests run inside the Docker build:

```bash
docker build --target test -t task-tracker:test .
```

A green exit code means all tests passed.

---

## 3. Start the full monitoring stack (local)

Bring up the app + Prometheus + Grafana + Node Exporter in one command:

```bash
docker compose up -d
```

| Service        | URL                        | Credentials  |
| -------------- | -------------------------- | ------------ |
| Task API       | http://localhost:3000      | —            |
| Prometheus     | http://localhost:9090      | —            |
| Grafana        | http://localhost:3001      | admin / admin |
| Node Exporter  | http://localhost:9100/metrics | —         |

Verify all scrape targets are **UP**:

```
http://localhost:9090/targets
```

Expected: `node (1/1 up)`, `task-api (1/1 up)`, `prometheus (1/1 up)`.

### Grafana dashboards

Both dashboards are **auto-provisioned** — no manual import needed.

**Task Tracker** (`/d/task-tracker`)

| Panel | Query |
|-------|-------|
| Requests/sec | `rate(http_requests_total[1m])` by handler/method/status |
| Latency p95 | `histogram_quantile(0.95, ...)` per handler |
| CPU usage % | `node_cpu_seconds_total` idle inverse |
| Memory used | `MemTotal - MemAvailable` |
| Error rate | `rate(http_requests_total{status=~"5.+"}[1m])` |
| In-flight requests | `http_requests_in_progress` |

**Node Exporter** (`/d/node-exporter`)

| Panel | Metric |
|-------|--------|
| CPU Usage (stat + timeseries) | `node_cpu_seconds_total` |
| Memory Usage (stat + timeseries) | `node_memory_*` |
| Root Disk Usage (stat) | `node_filesystem_*` |
| System Uptime (stat) | `node_boot_time_seconds` |
| Load Average | `node_load1/5/15` |
| Network I/O | `node_network_receive/transmit_bytes_total` |
| Disk I/O | `node_disk_read/written_bytes_total` |
| Filesystem Usage (bar gauge) | per-mountpoint `node_filesystem_*` |

---

## 4. Provision infrastructure (Terraform)

Creates: ECR repo, ECS cluster + service + task definition, ALB, target group, IAM roles, CloudWatch log group.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set aws_region, aws_profile, etc.

# Use Terraform via Docker (no local install needed)
alias tf='docker run --rm -it -v "$PWD:/tf" -w /tf \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -e AWS_REGION hashicorp/terraform:1.9'

tf init
tf plan -out tfplan
tf apply tfplan
```

Key outputs after apply:

```bash
tf output ecr_repository_url   # push images here
tf output alb_dns_name         # point your domain here
tf output ecs_cluster_name
tf output ecs_service_name
```

---

## 5. Provision EC2 host for monitoring (Ansible)

ECS Fargate is serverless — there is no underlying host to run Node Exporter on.
The Ansible playbook provisions a separate EC2 instance that runs:
- The app container (via systemd)
- Node Exporter (with `--pid=host` + host filesystem mount) for real host metrics

```bash
# 1. Create inventory from your EC2 instance
cp ansible/inventory.example.ini ansible/inventory.ini
# Edit inventory.ini — replace 1.2.3.4 with your EC2 public IP

# 2. Run the playbook
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml \
  -e "image=<ECR_URL>:latest"
```

After it completes:
- App is running at `http://<EC2_IP>:3000`
- Node Exporter is running at `http://<EC2_IP>:9100/metrics`

### Point Prometheus at production

Edit `monitoring/targets/node.json`:

```json
[
  { "targets": ["node-exporter:9100"], "labels": { "host": "ec2-app", "env": "local" } },
  { "targets": ["<EC2_IP>:9100"],      "labels": { "host": "ec2-app", "env": "prod"  } }
]
```

Edit `monitoring/targets/task-api.json`:

```json
[
  { "targets": ["app:3000"],      "labels": { "app": "task-api", "env": "local" } },
  { "targets": ["<EC2_IP>:3000"], "labels": { "app": "task-api", "env": "prod"  } }
]
```

**No restart needed** — Prometheus reloads target files every 60 seconds automatically.

> **EC2 Security Group**: open inbound TCP `9100` from your Prometheus IP (or `0.0.0.0/0` for testing).

---

## 6. CI/CD (GitHub Actions)

### Workflow 1 — Build & Push to ECR

**File:** `.github/workflows/ecr-docker-push.yml`
**Trigger:** `git tag v1.0.0 && git push origin v1.0.0`

Steps:
1. Checkout code
2. Authenticate with AWS + login to ECR
3. Build Docker image
4. Tag as `<version>` and `latest`
5. Push both tags to ECR

### Workflow 2 — Deploy to Production

**File:** `.github/workflows/deploy-prod.yml`
**Trigger:** Manual via GitHub Actions UI (`workflow_dispatch`) — choose the image version

Steps:
1. Fetch current ECS task definition
2. Update container image to the chosen version
3. Register new task definition revision
4. Update ECS service with `--force-new-deployment`
5. Wait for service to stabilise (rolling update, zero downtime)

### Required GitHub Secrets

| Secret | Value |
| ------ | ----- |
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_REGION` | e.g. `ap-south-1` |
| `ECR_REGISTRY` | e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com` |
| `ECR_REPOSITORY` | ECR repository name (e.g. `zocket`) |
| `ECS_CLUSTER` | ECS cluster name |
| `ECS_SERVICE` | ECS service name |
| `ECS_TASK` | ECS task definition family name |

---

## 7. API reference

Base URL: `http://zocket-alb-690003003.ap-south-1.elb.amazonaws.com`

| Method | Path | Body | Response |
| ------ | ---- | ---- | -------- |
| `POST` | `/tasks` | `{"title":"...","description":"...","status":"pending\|in_progress\|done"}` | `201` task object |
| `GET` | `/tasks` | — | `200` array, newest first |
| `GET` | `/healthz` | — | `200 {"status":"ok"}` |
| `GET` | `/metrics` | — | Prometheus text format |

```bash
ALB=http://zocket-alb-690003003.ap-south-1.elb.amazonaws.com

curl $ALB/healthz
curl -X POST $ALB/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"first","description":"test","status":"pending"}'
curl $ALB/tasks
```

---

## 8. Tear down

```bash
cd terraform
tf destroy
```

---

## Design decisions

| Decision | Why |
| -------- | --- |
| **FastAPI** | Async, minimal boilerplate, native Pydantic validation, `prometheus-fastapi-instrumentator` drop-in |
| **SQLite on a named volume** | Zero extra infra; production switch to RDS is a one-line `DATABASE_URL` change |
| **Multi-stage Dockerfile** | `test` stage runs pytest in the same env as production — CI uses `docker build --target test` |
| **ECS Fargate** | Serverless containers — no EC2 to patch or manage for the app |
| **ALB health checks + rolling deploy** | Zero-downtime deploys; unhealthy tasks are drained before new ones take traffic |
| **Tag-triggered ECR push** | Decouples image build from deployment; every `vX.Y.Z` tag is an immutable artifact |
| **`workflow_dispatch` deploy** | Explicit, auditable production deploys — you choose which version goes live |
| **Ansible for EC2 + Node Exporter** | Fargate has no host; a separate EC2 instance provisioned by Ansible gives real host metrics |
| **`file_sd_configs` in Prometheus** | Target files reload every 60s — add/remove EC2 IPs without restarting Prometheus |
| **Grafana auto-provisioning** | Datasource and dashboards are provisioned from files on startup — no manual UI steps |

---

## Challenges / trade-offs

- **SQLite on Fargate** — ECS tasks are ephemeral; data survives only within a single task lifetime. Switch to RDS for durability.
- **Node Exporter on macOS Docker Desktop** — `network_mode: host` is unsupported; metrics reflect the Docker VM, not the Mac. Works correctly on a real Linux host.
- **TLS** — ALB listens on port 80. Next step: attach an ACM certificate and add an HTTPS listener.
- **Remote Terraform state** — state kept local for simplicity; add an S3 backend block for team use.

---

## Bonus checklist

- [x] Zero-downtime deploy (ECS rolling update + ALB health checks)
- [x] Self-healing (ECS restarts failed tasks automatically)
- [x] ECS/Fargate deployment
- [x] Container registry (Amazon ECR)
- [x] Prometheus Node Exporter (host CPU, memory, disk, network)
- [x] Grafana dashboards (Task Tracker + Node Exporter — auto-provisioned)
- [x] `file_sd_configs` for dynamic production scrape targets (no Prometheus restart needed)
