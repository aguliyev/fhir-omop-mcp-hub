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
