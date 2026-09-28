"""MCP cohort-query server: 3 tools over WebAPI omop_csv (Streamable HTTP /mcp)."""

from mcp.server.fastmcp import FastMCP

from .executor import execute
from .translator import translate

# host/port live on the constructor in MCP SDK 1.29.1 (run() takes only
# transport/mount_path); 0.0.0.0 binds inside the container, the host
# publish stays 127.0.0.1 in compose.yaml.
mcp = FastMCP("omop-cohort", host="0.0.0.0", port=8000)


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
    mcp.run(transport="streamable-http")
