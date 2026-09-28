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
