# MCP Cohort-Query Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the primary deliverable: a Python MCP server with translator, executor, and chained cohort-query tools against WebAPI `omop_csv`.

**Architecture:** One persistent Streamable HTTP `mcp_server` container (Python 3.12, pinned MCP SDK, `httpx`) talks to the registered `omop_csv` WebAPI source. The translator supports only documented question templates, resolves concepts via WebAPI, and constructs valid Circe cohort JSON without executing it. The executor uses the pinned release's verified create/generate/status/count endpoints; the high-level tool chains both without losing provenance.

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
- Streamable HTTP endpoint `/mcp` on container port `8000`; configurable host port bound to `127.0.0.1`. Bare `mcp.run()` uses stdio and will not listen on the published port.
- Supported v1 templates: `type 2 diabetes` and `women with type 2 diabetes` (allow case/whitespace variations only). Reject other terms, combinations, negations and age filters instead of silently dropping constraints.
- The WebAPI plan must first prove the pinned release's vocabulary search, Circe expression, cohort lifecycle and results contracts against a running server. Never treat the illustrative snippets below as verified WebAPI paths or payloads.
- No PHI beyond synthetic demo data; no secrets in tracked files or logs.

---

## Planned File Structure

```text
mcp_server/{__init__.py,pyproject.toml,Dockerfile,server.py,translator.py,executor.py,models.py}
etc/mcp.env.example            # WEBAPI_BASE_URL, MCP_HOST_PORT
tests/mcp/{__init__.py,test_translator.py,test_executor.py,test_cohort_query.py,fixtures/concepts.json,fixtures/accepted_circe.json}
```

`models.py` owns the supported-template parser and provenance schema; `translator.py`/`executor.py` are thin WebAPI clients; `server.py` registers the three MCP tools. Capture `accepted_circe.json` from a cohort actually accepted by the pinned WebAPI before writing translation code; record the release and source of the fixture.

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
        self.assertEqual([(c.domain, c.search_term) for c in e.criteria],
                         [("Condition", "type 2 diabetes"), ("Gender", "female")])
    def test_unsupported_rejected(self):
        with self.assertRaises(ValueError):
            parse_expression("left-handed redheads")
if __name__ == "__main__":
    unittest.main()
```

`fixtures/concepts.json`: two real-shaped search hits captured from the pinned WebAPI for condition and gender; never assume fixed concept IDs across Athena releases. `fixtures/accepted_circe.json`: a valid expression from that same release, with `PrimaryCriteria`, condition concept set, and gender inclusion, verified by creating and generating a cohort against `omop_csv`. Record how both fixtures were obtained; no patient rows are checked in.

Run: `python3 -m unittest tests.mcp.test_translator -v`
Expected: FAIL (module missing).

- [ ] **Step 2: Implement the minimal subset in `models.py`**

Supported v1 subset (YAGNI — nothing else):

```python
from pydantic import BaseModel, Field
class Criterion(BaseModel):
    domain: str  # Condition | Gender only
    search_term: str
class CohortExpression(BaseModel):
    name: str
    criteria: list[Criterion]  # two-criterion template uses AND
class Provenance(BaseModel):
    source_key: str
    concept_ids: list[int]
    webapi_calls: list[str]
    cohort_id: int | None = None
    counts: dict[str, int] = Field(default_factory=dict)
def parse_expression(text: str) -> CohortExpression:
    t = " ".join(text.lower().split())
    crits = [Criterion(domain="Condition", search_term="type 2 diabetes")]
    if t == "type 2 diabetes":
        return CohortExpression(name=text, criteria=crits)
    if t == "women with type 2 diabetes":
        return CohortExpression(name=text, criteria=crits + [Criterion(domain="Gender", search_term="female")])
    raise ValueError(f"unsupported expression: {text!r}")
```

Full vocabulary-accurate resolution happens in Task 2; parse_expression never supplies concept IDs. Reject anything outside this subset with `ValueError`, never hallucinate IDs or silently omit a constraint.

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
    # Both the live client and test client receive the same whole search terms.
    out = translate("women with type 2 diabetes", search_fn=lambda term, domain: {
        "type 2 diabetes": [{"CONCEPT_ID": 201826, "CONCEPT_NAME": "Type 2 diabetes mellitus", "DOMAIN_ID": "Condition", "STANDARD_CONCEPT": "S"}],
        "female": [{"CONCEPT_ID": 8532, "CONCEPT_NAME": "Female", "DOMAIN_ID": "Gender", "STANDARD_CONCEPT": "S"}],
    }[term])
    self.assertEqual(out["provenance"]["concept_ids"], [201826, 8532])
    self.assertIn("PrimaryCriteria", out["cohort_definition"]["expression"])
```

Run: expect FAIL (no `translator.py`).

- [ ] **Step 2: Implement `translator.py`**

Use the exact search endpoint and response shape proven by the WebAPI plan. Pass each `Criterion.search_term` unchanged to both the injected test client and the live client; filter hits to the requested domain, valid standard concepts, and an exact or deliberately ranked name match. Raise a clear `ValueError` on no hit or ambiguity rather than indexing an empty list or taking an arbitrary first result. Starting from `fixtures/accepted_circe.json`, substitute the resolved condition/gender concept IDs into the correct Circe concept-set and inclusion-rule locations; return `{cohort_definition, provenance}` with both names, IDs, and every WebAPI request. Test that the resulting JSON is accepted by the pinned WebAPI (not merely by a stub). Translator must never execute the cohort.

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
        # Use the accepted Circe fixture and recorded WebAPI responses, not a
        # synthetic criteria object that WebAPI cannot execute.
        with open("tests/mcp/fixtures/accepted_circe.json") as f:
            definition = json.load(f)
        out = execute(definition, "omop_csv", api=FakeAPI())
        self.assertEqual(out["counts"]["persons"], 42)
if __name__ == "__main__": unittest.main()
```

Import `json` in the test; replace the fake response keys and routes with captures from the pinned WebAPI before expecting PASS. Add tests for a failed generation, missing cohort ID, timeout, and missing count: none may return zero as a successful cohort. Run: `python3 -m unittest tests.mcp.test_executor -v`
Expected: FAIL.

- [ ] **Step 2: Implement `executor.py`**

First capture successful create, generate, status, and count requests/responses from the pinned running WebAPI and make the fake client return those exact shapes. Only then implement `execute(definition, source_key, api=None)` against those paths. Validate `source_key == "omop_csv"` before any request; require a real cohort ID; poll that source's execution status with a bounded timeout; fail on a failed, unknown, or timed-out generation; obtain an actual result count without `dict.get(..., 0)` masking errors. Preserve all called URLs and source/cohort identifiers in provenance. Add a live test that the accepted Circe fixture yields a completed generation with a count equal to the corresponding `omop_csv_results.cohort` rows. The `/generate` and `/report/count` URLs shown in the original draft were guesses and must not be copied.

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
import json, unittest
from mcp_server.server import run_cohort_query
class TestChain(unittest.TestCase):
    def test_chain_summary(self):
        with open("tests/mcp/fixtures/accepted_circe.json") as f:
            definition = json.load(f)
        out = run_cohort_query("women with type 2 diabetes", "omop_csv",
            translate_fn=lambda q: {"cohort_definition": definition,
                                    "provenance": {"concept_ids": [1], "webapi_calls": ["GET vocabulary"]}},
            execute_fn=lambda d, s: {"cohort_id": 7, "counts": {"persons": 3},
                                      "provenance": {"cohort_id": 7, "webapi_calls": ["POST generation"]}})
        self.assertIn("3 persons", out["summary"])
        self.assertEqual(out["provenance"]["cohort_id"], 7)
        self.assertEqual(out["provenance"]["webapi_calls"], ["GET vocabulary", "POST generation"])
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
    if source_key != "omop_csv":
        raise ValueError("v1 supports only omop_csv")
    t = translate_fn(question)
    e = execute_fn(t["cohort_definition"], source_key)
    n = e["counts"]["persons"]
    return {"summary": f"{n} persons match '{question}' on {source_key}.",
            "cohort_definition": t["cohort_definition"], "counts": e["counts"],
            "provenance": {**t.get("provenance", {}), **e.get("provenance", {}),
                           "concept_ids": t["provenance"]["concept_ids"],
                           "webapi_calls": t["provenance"]["webapi_calls"] + e["provenance"]["webapi_calls"]}}
@mcp.tool()
def translate_tool(question: str, source_key: str = "omop_csv") -> dict:
    """Natural language -> inspectable cohort-definition JSON (no execution)."""
    if source_key != "omop_csv":
        raise ValueError("v1 supports only omop_csv")
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
    mcp.run(transport="streamable-http", host="0.0.0.0", port=8000)
```

One plain function (`run_cohort_query`, unit-testable) plus three thin tool wrappers — never two
same-named definitions, which would shadow the registered tool.

`pyproject.toml` starter (pin the MCP dependency to a verified exact version before committing):

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
      webapi_register: {condition: service_completed_successfully}
    environment:
      WEBAPI_BASE_URL: http://ohdsi_webapi:8080/WebAPI
    ports: ["127.0.0.1:${MCP_HOST_PORT:-8000}:8000"]
    restart: unless-stopped
```

Pin the MCP SDK to an exact version in the final `pyproject.toml` before committing (the unpinned line above is only a sketch); verify that version accepts the shown `FastMCP.run` arguments and change the invocation if necessary. Pin a Python image digest and test an actual `/mcp` initialize/tools/list call on port 8000. `0.0.0.0` is needed **inside** the container; the host publish stays `127.0.0.1` only. No `env_file`: host port lives in ignored `etc/setup.env`, loaded by `common.sh`; `WEBAPI_BASE_URL` is the fixed in-network address. `etc/mcp.env.example` is documentation only.

- [ ] **Step 3: Run all + commit**

```bash
python3 -m unittest discover -s tests/mcp -v
docker compose build mcp_server
git add mcp_server etc/mcp.env.example tests/mcp compose.yaml
git commit -m "feat: add mcp cohort-query server"
```

Expected: all unit tests PASS, image builds, and an MCP client can initialize and list exactly three tools at `/mcp`. The operator plan subsequently checks a live cohort end to end.

## Stop Rules

- Stop if WebAPI cohort endpoints differ — read the running WebAPI docs, adapt `executor.py`, never mock away the difference.
- Stop on new tool surface beyond the 3 v1 tools — extensibility is future work.
- Stop if `source_key` handling branches beyond the `!= omop_csv` reject — one source in v1.
