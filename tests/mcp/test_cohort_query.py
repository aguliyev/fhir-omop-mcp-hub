import json
import unittest

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

    def test_chain_rejects_unknown_source(self):
        with self.assertRaises(ValueError):
            run_cohort_query("type 2 diabetes", "omop_fhir",
                             translate_fn=lambda q: {}, execute_fn=lambda d, s: {})


if __name__ == "__main__":
    unittest.main()
