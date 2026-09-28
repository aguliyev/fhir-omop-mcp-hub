import json
import unittest

from mcp_server.executor import execute


def _definition():
    with open("tests/mcp/fixtures/accepted_circe.json") as f:
        return json.load(f)


class FakeAPI:
    """Returns the byte-level shapes WebAPI v2.15.2 serves (see PROVENANCE.md)."""

    def __init__(self, info=None):
        self.calls = []
        self._info = info if info is not None else [{
            "id": {"cohortDefinitionId": 7, "sourceId": 2},
            "status": "COMPLETE", "isValid": True, "isCanceled": False,
            "failMessage": None, "personCount": 42, "recordCount": 100}]

    def post(self, path, json=None):
        self.calls.append(f"POST {path}")
        return {"id": 7, "name": "x", "expressionType": "SIMPLE_EXPRESSION"}

    def get(self, path):
        self.calls.append(f"GET {path}")
        if path.endswith("/info"):
            return self._info
        return {"status": "STARTING", "executionId": 4,
                "jobParameters": {"cohort_definition_id": "7", "source_id": "2"}}


class TestExecutor(unittest.TestCase):
    def test_rejects_unknown_source(self):
        with self.assertRaises(ValueError):
            execute(_definition(), "omop_fhir", api=FakeAPI())

    def test_counts(self):
        # Use the accepted Circe fixture and recorded WebAPI responses, not a
        # synthetic criteria object that WebAPI cannot execute.
        out = execute(_definition(), "omop_csv", api=FakeAPI())
        self.assertEqual(out["counts"]["persons"], 42)
        self.assertEqual(out["provenance"]["cohort_id"], 7)

    def test_failed_generation_raises(self):
        info = [{"id": {"cohortDefinitionId": 7, "sourceId": 2},
                 "status": "COMPLETE", "isValid": False, "isCanceled": False,
                 "failMessage": "BadSqlGrammarException: omop_csv.CONDITION_OCCURRENCE missing",
                 "personCount": None, "recordCount": None}]
        with self.assertRaises(ValueError):
            execute(_definition(), "omop_csv", api=FakeAPI(info=info))

    def test_missing_cohort_id_raises(self):
        class NoId(FakeAPI):
            def post(self, path, json=None):
                self.calls.append(f"POST {path}")
                return {"name": "x"}  # no id
        with self.assertRaises(ValueError):
            execute(_definition(), "omop_csv", api=NoId())

    def test_timeout_raises(self):
        info = [{"id": {"cohortDefinitionId": 7, "sourceId": 2},
                 "status": "RUNNING", "isValid": False, "isCanceled": False,
                 "failMessage": None, "personCount": None, "recordCount": None}]
        with self.assertRaises(ValueError):
            execute(_definition(), "omop_csv", api=FakeAPI(info=info),
                    timeout=0.05, poll_interval=0.01)

    def test_missing_count_raises_not_zero(self):
        info = [{"id": {"cohortDefinitionId": 7, "sourceId": 2},
                 "status": "COMPLETE", "isValid": True, "isCanceled": False,
                 "failMessage": None, "personCount": None, "recordCount": None}]
        with self.assertRaises(ValueError):
            execute(_definition(), "omop_csv", api=FakeAPI(info=info))


if __name__ == "__main__":
    unittest.main()
