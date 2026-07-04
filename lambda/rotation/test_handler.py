import unittest

from handler import build_alter_user_sql


class HandlerTests(unittest.TestCase):
    def test_build_alter_user_sql_quotes_identifier_and_password(self):
        query = build_alter_user_sql('vaultops_user', "pa'ss")
        self.assertEqual(query, 'ALTER USER "vaultops_user" WITH PASSWORD \'pa\'\'ss\'')


if __name__ == '__main__':
    unittest.main()
