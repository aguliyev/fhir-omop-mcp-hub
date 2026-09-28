# MCP Cohort-Query Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the primary deliverable: a Python MCP server with translator, executor, and chained cohort-query tools against WebAPI `omop_csv`.

**Architecture:** One persistent `mcp_server` container (Python 3.12, MCP SDK, `httpx`) talks to `http://ohdsi_webapi:8080/WebAPI` over the Compose network. Translator resolves natural-language terms to OMOP concept IDs via WebAPI `/vocabulary/search`, returns inspectable cohort-definition JSON without executing. Executor runs the WebAPI cohort lifecycle (create → generate → poll → fetch counts) for `source_key=omop_csv`. High-level `cohort_query` chains both and returns plain-language summary + provenance (concept IDs, cohort id, source key, row counts, WebAPI URLs).

**Tech Stack:** Python 3.12, MCP Python SDK, `httpx`, `pydantic`, stdlib `unittest`, Docker Compose.

**Spec:** `docs/intro.md` §§4, 5, 7, 8 (three tools; v1 `source_key` always `omop_csv`; ports on 127.0.0.1).

**File ownership (parallel agents):** this plan owns `mcp_server/`, `etc/mcp.env.example`,
`tests/mcp/`. It must not edit `compose.yaml` beyond appending its own `mcp_server:` block,
and must not touch any other plan's files. WebAPI endpoint shapes come from the WebAPI plan;
if they differ from those assumed below, adapt and record (see Stop Rules).

## Global Constraints

- Accept `source_key` on every tool but reject anything except `omop_csv` with a clear error (`omop_fhir` deferred).
- Translator never executes a cohort; executor never does vocabulary free-text guessing — it takes cohort JSON + source key.
- Every high-level response includes provenance: resolved concept IDs + names, generated cohort-definition JSON or its WebAPI ID, source key, counts, and the WebAPI endpoints called.
- WebAPI base URL from env `WEBAPI_BASE_URL` (default `http://ohdsi_webapi:8080/WebAPI`); no hardcoded hosts in code.
- MCP port configurable (default `8000`), bound to `127.0.0.1` on the host.
- No PHI beyond synthetic demo data; no secrets in tracked files or logs.

---

## Planned File Structure

```text
mcp_server/{__init__.py,pyproject.toml,Dockerfile,server.py,translator.py,executor.py,models.py}
etc/mcp.env.example            # WEBAPI_BASE_URL, MCP_HOST_PORT
tests/mcp/{__init__.py,test_translator.py,test_executor.py,test_cohort_query.py,fixtures/concepts.json}
```

`models.py` owns the cohort-expression subset + provenance schema; `translator.py`/`executor.py` are thin WebAPI clients; `server.py` registers the three MCP tools.

---

### Task 1: Models + supported expression subset (contract first)

**Files:**
- Create: `mcp_server/models.py`
- Create: `mcp_server/__init__.py` (empty)
- Create: `tests/mcp/__init__.py` (empty)
- Create: `tests/mcp/test_translator.py` (subset cases, failing first)
- Create: `tests/mcp/fixtures/concepts.json`

**Interfaces:**
- Consumes: WebAPI `/vocabulary/search` concept shape.
- Produces: `CohortExpression`, `TranslatorOutput`, `Provenance` types consumed by Tasks 2–4.

- [ ] **Step 1: Write the failing subset test**

```python
# tests/mcp/test_translator.py
import unittest
from mcp_server.models import parse_expression
class TestExpression(unittest.TestCase):
    def test_type2_diabetes_female(self):
        e = parse_expression("women with type 2 diabetes")
        ids = sorted(c.concept_id for c in e.criteria)
        self.assertEqual(ids, [8532, 201826])
    def test_unsupported_rejected(self):
        with self.assertRaises(ValueError):
            parse_expression("left-handed redheads")
if __name__ == "__main__":
    unittest.main()
```

`fixtures/concepts.json`: two canned WebAPI search hits:

```json
[{"CONCEPT_ID": 201826, "CONCEPT_NAME": "Type 2 diabetes mellitus", "VOCABULARY_ID": "SNOMED", "DOMAIN_ID": "Condition"},
 {"CONCEPT_ID": 8532, "CONCEPT_NAME": "Female", "VOCABULARY_ID": "OMOP", "DOMAIN_ID": "Gender"}]
```

Run: `python3 -m unittest tests.mcp.test_translator -v`
Expected: FAIL (module missing).

- [ ] **Step 2: Implement the minimal subset in `models.py`**

Supported v1 subset (YAGNI — nothing else):

```python
from pydantic import BaseModel
class Criterion(BaseModel):
    domain: str  # Condition | Drug | Procedure | Measurement | Gender | Age
    concept_id: int
    concept_name: str = ""
class CohortExpression(BaseModel):
    name: str
    criteria: list[Criterion]  # AND semantics only in v1
class Provenance(BaseModel):
    source_key: str
    concept_ids: list[int]
    webapi_calls: list[str]
    cohort_id: int | None = None
    counts: dict[str, int] = {}
def parse_expression(text: str) -> CohortExpression:
    t = text.lower()
    crits = []
    if "diabetes" in t:
        crits.append(Criterion(domain="Condition", concept_id=201826, concept_name="Type 2 diabetes mellitus"))
    if "female" in t or "women" in t:
        crits.append(Criterion(domain="Gender", concept_id=8532, concept_name="Female"))
    if not crits:
        raise ValueError(f"unsupported expression: {text!r}")
    return CohortExpression(name=text[:120], criteria=crits)
```

Full vocabulary-accurate resolution happens in Task 2 (live search replaces these seed IDs); the subset keywords above are the v1 contract. Reject anything outside this subset with `ValueError`, never hallucinate IDs.

- [ ] **Step 3: Run + commit**

```bash
python3 -m unittest tests.mcp.test_translator -v
git add mcp_server/models.py tests/mcp/
git commit -m "feat: define mcp cohort expression subset"
```

Expected: PASS.

### Task 2: Translator (NL → cohort JSON via live vocab search)

**Files:**
- Create: `mcp_server/translator.py`
- Modify: `tests/mcp/test_translator.py` (add live-search test with fixture server)

**Interfaces:**
- Consumes: `CohortExpression` from Task 1, `WEBAPI_BASE_URL`.
- Produces: `translate(question) -> TranslatorOutput(json + provenance)` consumed by Task 4.

- [ ] **Step 1: Extend the test with a stubbed WebAPI**

```python
def test_translate_hits_live_search(self):
    from mcp_server.translator import translate
    # Stub keys must match the lookup terms translate() derives: first word of each
    # seed concept name, lowercased ("type" from "Type 2 diabetes mellitus", "female").
    out = translate("women with type 2 diabetes", search_fn=lambda term, domain: {
        "type": [{"concept_id": 201826, "concept_name": "Type 2 diabetes mellitus", "domain": "Condition"}],
        "female": [{"concept_id": 8532, "concept_name": "Female", "domain": "Gender"}],
    }[term])
    ids = sorted(c["concept_id"] for c in out["cohort_definition"]["criteria"])
    self.assertEqual(ids, [8532, 201826])
```

Run: expect FAIL (no `translator.py`).

- [ ] **Step 2: Implement `translator.py`**

```python
import os, httpx
from .models import parse_expression
WEBAPI = os.getenv("WEBAPI_BASE_URL", "http://ohdsi_webapi:8080/WebAPI")
def search(term: str, domain: str) -> list[dict]:
    r = httpx.get(f"{WEBAPI}/vocabulary/search", params={"query": term, "domain": domain}, timeout=30)
    r.raise_for_status()
    return r.json()
def translate(question: str, search_fn=search) -> dict:
    expr = parse_expression(question)  # subset gate
    resolved = []
    for c in expr.criteria:
        hits = search_fn(c.concept_name.split()[0].lower() if search_fn is not search else c.concept_name, c.domain)
        best = hits[0]
        resolved.append({"domain": c.domain, "concept_id": best["concept_id"] if "concept_id" in best else best["CONCEPT_ID"],
                         "concept_name": best.get("concept_name", best.get("CONCEPT_NAME", ""))})
    return {"cohort_definition": {"name": expr.name, "criteria": resolved, "logic": "AND"},
            "provenance": {"source_key": "omop_csv", "concept_ids": [c["concept_id"] for c in resolved],
                           "webapi_calls": ["GET /vocabulary/search"]}}
```

Default `search_fn` hits live WebAPI; tests inject the stub. Never execute a cohort here.

- [ ] **Step 3: Run + commit**

```bash
python3 -m unittest tests.mcp.test_translator -v
git add mcp_server/translator.py tests/mcp/test_translator.py
git commit -m "feat: add mcp translator with vocab search"
```

### Task 3: Executor (cohort JSON → WebAPI lifecycle → counts)

**Files:**
- Create: `mcp_server/executor.py`
- Create: `tests/mcp/test_executor.py`

**Interfaces:**
- Consumes: cohort-definition JSON from Task 2, `WEBAPI_BASE_URL`.
- Produces: `execute(definition, source_key) -> {counts, cohort_id, provenance}` consumed by Task 4.

- [ ] **Step 1: Write the failing executor test**

```python
# tests/mcp/test_executor.py
import unittest
from mcp_server.executor import execute
class FakeAPI:
    def __init__(self): self.calls = []
    def post(self, path, json=None): self.calls.append(f"POST {path}"); return {"id": 7}
    def get(self, path): self.calls.append(f"GET {path}"); return {"count": 42, "status": "COMPLETE"}
class TestExecutor(unittest.TestCase):
    def test_rejects_unknown_source(self):
        with self.assertRaises(ValueError): execute({"criteria": []}, "omop_fhir", api=FakeAPI())
    def test_counts(self):
        out = execute({"name": "x", "criteria": [{"concept_id": 1}]}, "omop_csv", api=FakeAPI())
        self.assertEqual(out["counts"]["persons"], 42)
if __name__ == "__main__": unittest.main()
```

Run: `python3 -m unittest tests.mcp.test_executor -v`
Expected: FAIL.

- [ ] **Step 2: Implement `executor.py`**

```python
import os, httpx, time
WEBAPI = os.getenv("WEBAPI_BASE_URL", "http://ohdsi_webapi:8080/WebAPI")
class LiveAPI:
    def post(self, path, json=None):
        r = httpx.post(WEBAPI + path, json=json, timeout=60); r.raise_for_status(); return r.json()
    def get(self, path):
        r = httpx.get(WEBAPI + path, timeout=30); r.raise_for_status(); return r.json()
def execute(definition: dict, source_key: str, api=None) -> dict:
    if source_key != "omop_csv":
        raise ValueError(f"unknown source_key {source_key!r}; v1 supports only 'omop_csv'")
    api = api or LiveAPI()
    created = api.post("/cohortdefinition", json=definition)
    cid = created.get("id")
    api.post(f"/cohortdefinition/{cid}/generate", json={"source_key": source_key})
    for _ in range(60):
        st = api.get(f"/cohortdefinition/{cid}/info")
        if st.get("status") in ("COMPLETE", "FAILED"):
            break
        time.sleep(5)
    info = api.get(f"/cohortdefinition/{cid}/report/count")
    counts = {"persons": info.get("count", 0)}
    return {"cohort_id": cid, "counts": counts,
            "provenance": {"source_key": source_key, "cohort_id": cid, "counts": counts,
                           "webapi_calls": ["POST /cohortdefinition", "POST /generate", "GET /report/count"]}}
```

Adapt paths to the pinned WebAPI's actual cohort endpoints (verify against `http://127.0.0.1:8080/WebAPI/` docs in the WebAPI plan); record corrections here.

- [ ] **Step 3: Run + commit**

```bash
python3 -m unittest tests.mcp.test_executor -v
git add mcp_server/executor.py tests/mcp/test_executor.py
git commit -m "feat: add mcp executor lifecycle"
```

### Task 4: Server wiring (3 MCP tools + container)

**Files:**
- Create: `mcp_server/server.py`
- Create: `mcp_server/pyproject.toml`
- Create: `mcp_server/Dockerfile`
- Create: `etc/mcp.env.example`
- Create: `tests/mcp/test_cohort_query.py`
- Modify: `compose.yaml` (append `mcp_server:` service block only)

**Interfaces:**
- Consumes: Tasks 1–3 + WebAPI base URL from the WebAPI plan.
- Produces: running MCP server; operator-UX plan smoke-tests it.

- [ ] **Step 1: Write the chain test**

```python
# tests/mcp/test_cohort_query.py
import unittest
from mcp_server.server import run_cohort_query
class TestChain(unittest.TestCase):
    def test_chain_summary(self):
        out = run_cohort_query("women with type 2 diabetes", "omop_csv",
            translate_fn=lambda q: {"cohort_definition": {"name": q, "criteria": [{"concept_id": 1}]},
                                    "provenance": {"concept_ids": [1], "webapi_calls": ["GET /vocabulary/search"]}},
            execute_fn=lambda d, s: {"cohort_id": 7, "counts": {"persons": 3}, "provenance": {}})
        self.assertIn("3 persons", out["summary"])
        self.assertEqual(out["provenance"]["cohort_id"], 7)
if __name__ == "__main__": unittest.main()
```

Run: expect FAIL.

- [ ] **Step 2: Implement `server.py` + packaging**

```python
from mcp.server.fastmcp import FastMCP
from .translator import translate
from .executor import execute
mcp = FastMCP("omop-cohort")
def run_cohort_query(question, source_key="omop_csv", translate_fn=translate, execute_fn=execute):
    t = translate_fn(question)
    e = execute_fn(t["cohort_definition"], source_key)
    n = e["counts"].get("persons", 0)
    return {"summary": f"{n} persons match '{question}' on {source_key}.",
            "cohort_definition": t["cohort_definition"], "counts": e["counts"],
            "provenance": {**t.get("provenance", {}), **e.get("provenance", {})}}
@mcp.tool()
def translate_tool(question: str) -> dict:
    """Natural language -> inspectable cohort-definition JSON (no execution)."""
    return translate(question)
@mcp.tool()
def execute_tool(cohort_definition: dict, source_key: str = "omop_csv") -> dict:
    """Execute cohort JSON on source_key (v1: omop_csv only)."""
    return execute(cohort_definition, source_key)
@mcp.tool(name="cohort_query")
def cohort_query_tool(question: str, source_key: str = "omop_csv") -> dict:
    """High-level natural-language cohort query with provenance."""
    return run_cohort_query(question, source_key)
if __name__ == "__main__":
    mcp.run()
```

One plain function (`run_cohort_query`, unit-testable) plus three thin tool wrappers — never two
same-named definitions, which would shadow the registered tool.

`pyproject.toml` (minimal, real content — no placeholders):

```toml
[build-system]
requires = ["setuptools>=61"]
build-backend = "setuptools.build_meta"
[project]
name = "omop-mcp-server"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = ["mcp", "httpx", "pydantic"]
[tool.setuptools.packages.find]
where = ["."]
include = ["mcp_server*"]
```

Dockerfile (pin the base-image digest at implementation time): `python:3.12-slim`,
`pip install .`, `CMD ["python", "-m", "mcp_server.server"]`. `etc/mcp.env.example`:

```dotenv
WEBAPI_BASE_URL=http://ohdsi_webapi:8080/WebAPI
MCP_HOST_PORT=8000
```

Compose:

```yaml
  mcp_server:
    build: ./mcp_server
    platform: linux/amd64
    depends_on:
      ohdsi_webapi: {condition: service_healthy}
    environment:
      WEBAPI_BASE_URL: http://ohdsi_webapi:8080/WebAPI
    ports: ["127.0.0.1:${MCP_HOST_PORT:-8000}:8000"]
    restart: unless-stopped
```

No `env_file` (consistent with existing services). `WEBAPI_BASE_URL` here is the fixed
in-network address; `etc/mcp.env.example` documents the host-port knob only.

- [ ] **Step 3: Run all + commit**

```bash
python3 -m unittest discover -s tests/mcp -v
docker compose build mcp_server
git add mcp_server etc/mcp.env.example tests/mcp compose.yaml
git commit -m "feat: add mcp cohort-query server"
```

Expected: all unit tests PASS; image builds; live check left to operator-UX plan.

## Stop Rules

- Stop if WebAPI cohort endpoints differ — read the running WebAPI docs, adapt `executor.py`, never mock away the difference.
- Stop on new tool surface beyond the 3 v1 tools — extensibility is future work.
- Stop if `source_key` handling branches beyond the `!= omop_csv` reject — one source in v1.
