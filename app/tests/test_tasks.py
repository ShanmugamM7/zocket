def test_health(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_create_and_list_tasks(client):
    assert client.get("/tasks").json() == []

    payload = {"title": "Write report", "description": "Q1 numbers", "status": "pending"}
    r = client.post("/tasks", json=payload)
    assert r.status_code == 201
    created = r.json()
    assert created["id"] == 1
    assert created["title"] == "Write report"

    listed = client.get("/tasks").json()
    assert len(listed) == 1
    assert listed[0]["title"] == "Write report"


def test_create_task_validation(client):
    r = client.post("/tasks", json={"title": ""})
    assert r.status_code == 422

    r = client.post("/tasks", json={"title": "ok", "status": "bogus"})
    assert r.status_code == 422


def test_metrics_endpoint_exposed(client):
    client.get("/tasks")
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "http_requests_total" in r.text or "http_request_duration_seconds" in r.text
