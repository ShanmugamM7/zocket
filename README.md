# Task Tracker — DevOps Take-Home

A FastAPI Task Tracker service, containerized, provisioned on AWS with Terraform,
deployed by Ansible, shipped through GitHub Actions, and monitored with
Prometheus + Grafana + Node Exporter.

---

## Architecture

```
              ┌─────────────────────────────────────────────────────────────┐
              │                       Developer                              │
              └───────────────┬─────────────────────────────────────────────┘
                              │ git push main
                              ▼
              ┌─────────────────────────────────────────────────────────────┐
              │  GitHub Actions (.github/workflows/ci-cd.yml)               │
              │  1. pytest (Docker test stage)                              │
              │  2. docker build & push  →  GHCR                            │
              │  3. SSH into EC2  →  pull image  →  systemctl restart       │
              └───────────────┬─────────────────────────────────────────────┘
                              │
                              ▼
   ┌──────────────────────────────────────────────────────────────────────┐
   │                            AWS (Terraform)                            │
   │                                                                       │
   │   ┌──────────────────────────────┐     ┌──────────────────────────┐   │
   │   │ EC2 t3.micro (Ubuntu 22.04)  │     │ S3 bucket (logs/artifacts)│  │
   │   │  ├── docker engine            │◀───┤ versioned + SSE + private │  │
   │   │  ├── task-api  :3000          │     └──────────────────────────┘   │
   │   │  ├── node_exporter :9100      │     ┌──────────────────────────┐   │
   │   │  ├── prometheus  :9090*       │     │ Security Group           │   │
   │   │  └── grafana     :3001*       │◀────┤ 22, 80, 3000, 9090,      │   │
   │   └──────────────────────────────┘     │ 3001, 9100               │   │
   │                                          └──────────────────────────┘   │
   │   * Prometheus + Grafana are optional and brought up via docker-compose │
   └──────────────────────────────────────────────────────────────────────┘
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
└── .github/workflows/ci-cd.yml
```

---

## Prerequisites

- Docker Desktop (or any Docker engine) — used for local runs, building, and tests.
- AWS account + credentials available to Terraform (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` or `aws configure`).
- A GitHub repository fork to drive CI/CD.

You **do not** need Terraform, Ansible, Python, or pytest installed on the host —
everything runs through containers.

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
# Edit ssh_allowed_cidr to your IP, set public_key_path if you have a key.

# Terraform via Docker (no local install needed):
alias tf='docker run --rm -it -v "$PWD:/tf" -w /tf \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
    -e AWS_REGION hashicorp/terraform:1.9'

tf init
tf plan -out tfplan
tf apply tfplan
```

Outputs:

| Output        | Purpose                                       |
| ------------- | --------------------------------------------- |
| `public_ip`   | EC2 public IP                                 |
| `public_dns`  | EC2 public DNS                                |
| `bucket_name` | S3 artifacts/logs bucket                      |
| `app_url`     | Base URL of the deployed app                  |
| `ssh_command` | Ready-to-paste `ssh -i ... ubuntu@...`        |

Terraform also writes `ansible/inventory.ini` automatically.

If `public_key_path` was empty, Terraform generates `terraform/generated_id_rsa`
(mode 0600) for you to SSH with.

---

## 3. Deploy the app (Ansible)

```bash
# From the project root:
docker run --rm -it \
  -v "$PWD/ansible:/work" \
  -v "$PWD/terraform/generated_id_rsa:/work/key:ro" \
  -w /work cytopia/ansible:latest \
  ansible-playbook -i inventory.ini playbook.yml \
    -e image=ghcr.io/<owner>/<repo>:latest \
    -e registry_username=<gh-user> \
    -e registry_password=<gh-token>
```

The playbook:

1. Installs Docker CE + the compose plugin
2. (Optional) Logs into GHCR / Docker Hub
3. Pulls the image
4. Writes a `task-api.service` systemd unit (auto-restart on failure)
5. Starts the container on port `3000`
6. Runs `node_exporter` on `:9100`
7. Polls `/healthz` until the app is up

---

## 4. CI/CD

The workflow at [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml)
runs on every push to `main`:

1. **test** — builds the Docker `test` stage (pytest)
2. **build-and-push** — builds the `runtime` image, tags `:<sha>` + `:latest`, pushes to GHCR
3. **deploy** — SSHes into EC2, pulls the new image, rewrites the systemd unit, and restarts (zero-downtime restart since systemd replaces the container in <1s and `/healthz` is polled)

Required GitHub Secrets:

| Secret         | Value                                              |
| -------------- | -------------------------------------------------- |
| `EC2_HOST`     | Terraform output `public_ip`                       |
| `EC2_USER`     | `ubuntu`                                           |
| `EC2_SSH_KEY` | Contents of `terraform/generated_id_rsa`           |

GHCR auth uses the workflow's built-in `GITHUB_TOKEN` (no manual setup needed).

---

## 5. API reference

| Method | Path        | Body                                                | Notes                |
| ------ | ----------- | --------------------------------------------------- | -------------------- |
| `POST` | `/tasks`    | `{"title": "...", "description": "...", "status": "pending\|in_progress\|done"}` | 201 returns the row  |
| `GET`  | `/tasks`    | —                                                   | newest first         |
| `GET`  | `/healthz`  | —                                                   | liveness probe       |
| `GET`  | `/metrics`  | —                                                   | Prometheus exposition |

Smoke test against a deployed host:

```bash
HOST=$(cd terraform && tf output -raw public_ip)
curl -s http://$HOST:3000/healthz
curl -s -X POST http://$HOST:3000/tasks \
  -H 'Content-Type: application/json' \
  -d '{"title":"first","status":"pending"}'
curl -s http://$HOST:3000/tasks
```

---

## 6. Monitoring

- **App metrics** — `prometheus-fastapi-instrumentator` exposes `/metrics` on the app itself.
- **Host metrics** — Node Exporter on `:9100` (installed by Ansible).
- **Prometheus + Grafana** — run the optional containers in `docker-compose.yml`. The Grafana dashboard `Task Tracker` is auto-provisioned with RPS, p95 latency, CPU%, and memory panels.

To run the monitoring stack *on the EC2 host* (in addition to what the playbook installs):

```bash
ssh -i terraform/generated_id_rsa ubuntu@$HOST
git clone <repo> && cd <repo>
docker compose up -d prometheus grafana
```

Then open `http://<public_ip>:3001` (Grafana, `admin`/`admin`) and `http://<public_ip>:9090` (Prometheus). Both ports are open only to `ssh_allowed_cidr`.

---

## 7. Tear down

```bash
cd terraform && tf destroy
```

This deletes the EC2 instance, security group, IAM role, key pair, and S3 bucket
(`force_destroy = true`).

---

## Design decisions

| Decision                              | Why                                                                 |
| ------------------------------------- | ------------------------------------------------------------------- |
| **FastAPI**                           | Tiny surface, async-ready, has a Prometheus instrumentor on a shelf |
| **SQLite on a Docker volume**         | Zero extra infra; assignment says SQLite *or* Postgres              |
| **Multi-stage Dockerfile w/ test stage** | The CI test job is `docker build --target test` — same exact env as runtime |
| **GHCR (not Docker Hub)**             | Free, repo-scoped, no extra credential setup beyond `GITHUB_TOKEN` |
| **systemd unit instead of `docker run`** | Survives reboots, restarts on crash → satisfies the "self-healing" bonus |
| **Generated SSH key as a fallback**   | Lowers friction for evaluators — they don't need to wire up keys    |
| **Terraform writes the Ansible inventory** | No manual copy/paste between IaC and config-management              |
| **`docker compose` for the monitoring stack** | Keeps it optional and trivially reproducible locally and on the EC2 |

## Challenges / trade-offs

- **Truly zero-downtime on a single node** would need a second container on a different port + nginx swap. The current `systemctl restart` swap is ~1 second; sufficient for the assignment but called out honestly.
- **State** — SQLite means the container can move but the host cannot. For production I'd switch to RDS + remove the volume.
- **TLS** — port 80 is open but nothing terminates HTTPS. Easiest next step: Caddy as a reverse proxy with Let's Encrypt.
- **Remote Terraform state** — kept local for simplicity; an S3 backend block is one paragraph away.

## Bonus checklist

- [x] Zero-downtime *enough* deploy (systemd restart + health poll)
- [x] Self-healing (`Restart=always` in systemd, `--restart=always` on monitoring containers)
- [ ] ECS/Fargate (skipped to keep the footprint single-EC2 per the brief)
