"""Cohort JSON -> WebAPI create/generate/status/count lifecycle (never vocab-guesses)."""

import os
import time

import httpx

SOURCE_KEY = "omop_csv"
BASE_URL = os.environ.get("WEBAPI_BASE_URL", "http://ohdsi_webapi:8080/WebAPI")
PENDING = ("STARTING", "RUNNING", "PENDING")


class LiveAPI:
    def __init__(self, base_url=None):
        self._base = base_url or BASE_URL

    def post(self, path, json=None):
        with httpx.Client(timeout=60) as client:
            r = client.post(self._base + path, json=json)
            r.raise_for_status()
            return r.json()

    def get(self, path):
        with httpx.Client(timeout=60) as client:
            r = client.get(self._base + path)
            r.raise_for_status()
            return r.json()


def execute(definition, source_key="omop_csv", api=None, timeout=300, poll_interval=5):
    if source_key != SOURCE_KEY:
        raise ValueError(f"v1 supports only {SOURCE_KEY}: {source_key!r}")
    api = api or LiveAPI()
    calls = []
    created = api.post("/cohortdefinition/", json=definition)
    calls.append("POST /cohortdefinition/")
    cohort_id = created.get("id") if isinstance(created, dict) else None
    if not isinstance(cohort_id, int):
        raise ValueError(f"cohort create returned no id: {created!r}")
    gen_path = f"/cohortdefinition/{cohort_id}/generate/{source_key}"
    api.get(gen_path)
    calls.append(f"GET {gen_path}")
    info_path = f"/cohortdefinition/{cohort_id}/info"
    deadline = time.monotonic() + timeout
    entry = None
    while True:
        infos = api.get(info_path)
        if f"GET {info_path}" not in calls:
            calls.append(f"GET {info_path}")
        matches = [e for e in (infos or [])
                   if e.get("id", {}).get("cohortDefinitionId") == cohort_id]
        if matches:
            entry = matches[-1]
            if entry.get("status") not in PENDING:
                break
        if time.monotonic() >= deadline:
            raise ValueError(f"generation of cohort {cohort_id} timed out after {timeout}s")
        time.sleep(poll_interval)
    if entry.get("isCanceled") or entry.get("failMessage") or entry.get("status") != "COMPLETE":
        raise ValueError(f"generation of cohort {cohort_id} failed: "
                         f"status={entry.get('status')} fail={entry.get('failMessage')}")
    persons, records = entry.get("personCount"), entry.get("recordCount")
    if persons is None or records is None:
        raise ValueError(f"generation of cohort {cohort_id} returned no counts: {entry!r}")
    counts = {"persons": persons, "records": records}
    return {"cohort_id": cohort_id, "counts": counts,
            "provenance": {"source_key": source_key, "concept_ids": [],
                           "webapi_calls": calls, "cohort_id": cohort_id, "counts": counts}}
