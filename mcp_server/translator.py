"""Natural language -> inspectable cohort-definition JSON (never executes)."""

import copy
import os

import httpx

from .models import parse_expression

SOURCE_KEY = "omop_csv"
BASE_URL = os.environ.get("WEBAPI_BASE_URL", "http://ohdsi_webapi:8080/WebAPI")

# OMOP CDM Gender constants. This Athena slice (CVX/LOINC/RxNorm/SNOMED/UCUM)
# ships no standard Gender concept, so live search cannot resolve "female";
# 8532/8507 are CDM constants (vocabulary "Gender"), not Athena-release IDs.
GENDER_CONSTANTS = {"female": (8532, "FEMALE"), "male": (8507, "MALE")}


def live_search(term, domain):
    """POST /vocabulary/{source}/search, return raw hit dicts (UPPER_CASE keys)."""
    with httpx.Client(timeout=30) as client:
        r = client.post(f"{BASE_URL}/vocabulary/{SOURCE_KEY}/search", json={"QUERY": term})
        r.raise_for_status()
        return r.json()


def _pick(term, domain, hits):
    in_domain = [h for h in (hits or []) if h.get("DOMAIN_ID") == domain]
    valid = [h for h in in_domain
             if h.get("STANDARD_CONCEPT") == "S" and h.get("INVALID_REASON", "V") in ("V", "", None)]
    if not valid:
        return None
    t = term.casefold()
    exact = [h for h in valid if h.get("CONCEPT_NAME", "").casefold() == t]
    if len(exact) == 1:
        return exact[0]
    if exact:
        raise ValueError(f"ambiguous {domain} term {term!r}: {[h['CONCEPT_NAME'] for h in exact]}")
    starts = sorted([h for h in valid if h.get("CONCEPT_NAME", "").casefold().startswith(t)],
                    key=lambda h: len(h.get("CONCEPT_NAME", "")))
    if starts and (len(starts) == 1 or len(starts[0].get("CONCEPT_NAME", "")) < len(starts[1].get("CONCEPT_NAME", ""))):
        return starts[0]
    raise ValueError(f"ambiguous {domain} term {term!r}: {[h['CONCEPT_NAME'] for h in valid[:5]]}")


def _concept_entry(concept_id, name, domain, vocab, code="", cls=""):
    return {"CONCEPT_ID": concept_id, "CONCEPT_NAME": name,
            "STANDARD_CONCEPT": "S", "STANDARD_CONCEPT_CAPTION": "Standard",
            "INVALID_REASON": "V", "INVALID_REASON_CAPTION": "Valid",
            "CONCEPT_CODE": code, "DOMAIN_ID": domain,
            "VOCABULARY_ID": vocab, "CONCEPT_CLASS_ID": cls}


def _build_definition(question, cond, gender):
    """Circe SIMPLE_EXPRESSION mirroring tests/mcp/fixtures/accepted_circe.json."""
    concept_sets = [{"id": 0, "name": cond[1], "expression": {"items": [{
        "concept": _concept_entry(cond[0], cond[1], "Condition", cond[2]),
        "isExcluded": False, "includeDescendants": True, "includeMapped": False}]}}]
    rules = []
    if gender is not None:
        concept_sets.append({"id": 1, "name": gender[1], "expression": {"items": [{
            "concept": _concept_entry(gender[0], gender[1], "Gender", "Gender", cls="Gender"),
            "isExcluded": False, "includeDescendants": False, "includeMapped": False}]}})
        rules.append({"name": gender[1], "expression": {
            "Type": "ALL", "CriteriaList": [],
            "DemographicCriteriaList": [{"Gender": [
                _concept_entry(gender[0], gender[1], "Gender", "Gender", cls="Gender")]}],
            "Groups": []}})
    return {"name": question, "description": question,
            "expressionType": "SIMPLE_EXPRESSION",
            "expression": {
                "ConceptSets": concept_sets,
                "PrimaryCriteria": {
                    "CriteriaList": [{"ConditionOccurrence": {"CodesetId": 0}}],
                    "ObservationWindow": {"PriorDays": 0, "PostDays": 0},
                    "PrimaryCriteriaLimit": {"Type": "First"}},
                "QualifiedLimit": {"Type": "First"},
                "ExpressionLimit": {"Type": "First"},
                "InclusionRules": rules,
                "CensoringCriteria": [],
                "CollapseSettings": {"CollapseType": "ERA", "EraPad": 0},
                "CensorWindow": {},
                "cdmVersionRange": ">=5.0.0"}}


def translate(question, search_fn=None):
    expr = parse_expression(question)  # ValueError on unsupported templates
    search_fn = search_fn or live_search
    calls, cond, gender = [], None, None
    for c in expr.criteria:
        hits = search_fn(c.search_term, c.domain)
        calls.append(f"POST /vocabulary/{SOURCE_KEY}/search QUERY={c.search_term!r}")
        hit = _pick(c.search_term, c.domain, hits)
        if hit is None:
            if c.domain == "Gender" and c.search_term.casefold() in GENDER_CONSTANTS:
                gid, gname = GENDER_CONSTANTS[c.search_term.casefold()]
                gender = (gid, gname, "Gender")
                calls[-1] += " -> CDM Gender constant (no standard Gender hit in Athena slice)"
                continue
            raise ValueError(f"no standard {c.domain} concept for {c.search_term!r}")
        if c.domain == "Condition":
            cond = (hit["CONCEPT_ID"], hit["CONCEPT_NAME"], hit.get("VOCABULARY_ID", ""))
        elif c.domain == "Gender":
            gender = (hit["CONCEPT_ID"], hit["CONCEPT_NAME"], hit.get("VOCABULARY_ID", ""))
        else:  # ponytail: unreachable via parse_expression; guard if subset grows
            raise ValueError(f"unsupported domain: {c.domain}")
    if cond is None:
        raise ValueError(f"no condition resolved for {question!r}")
    resolved = [cond[0]] + ([gender[0]] if gender else [])
    definition = _build_definition(question, cond, gender)
    return {"cohort_definition": definition,
            "provenance": {"source_key": SOURCE_KEY,
                           "concept_ids": resolved,
                           "concept_names": [cond[1]] + ([gender[1]] if gender else []),
                           "webapi_calls": calls,
                           "cohort_id": None, "counts": {}}}
