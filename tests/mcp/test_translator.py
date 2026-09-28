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

    def test_translate_hits_live_search(self):
        from mcp_server.translator import translate
        # Both the live client and test client receive the same whole search terms.
        out = translate("women with type 2 diabetes", search_fn=lambda term, domain: {
            "type 2 diabetes": [{"CONCEPT_ID": 201826, "CONCEPT_NAME": "Type 2 diabetes mellitus", "DOMAIN_ID": "Condition", "STANDARD_CONCEPT": "S"}],
            "female": [{"CONCEPT_ID": 8532, "CONCEPT_NAME": "Female", "DOMAIN_ID": "Gender", "STANDARD_CONCEPT": "S"}],
        }[term])
        self.assertEqual(out["provenance"]["concept_ids"], [201826, 8532])
        self.assertIn("PrimaryCriteria", out["cohort_definition"]["expression"])


if __name__ == "__main__":
    unittest.main()
