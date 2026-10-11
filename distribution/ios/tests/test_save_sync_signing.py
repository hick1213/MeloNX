"""Tests the actual verifier predicate without reading accounts or profiles."""
import ast
import fnmatch
from pathlib import Path
import unittest

source = Path(__file__).parents[1].joinpath('verify-save-sync-signing.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
functions = [n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == 'cloud_documents_allowed']
namespace = {'fnmatch': fnmatch}
exec(compile(ast.Module(body=functions, type_ignores=[]), '<verifier>', 'exec'), namespace)

class SigningTests(unittest.TestCase):
    def test_profile_patterns_allow_only_requested_documents_service(self):
        predicate = namespace['cloud_documents_allowed']
        for permitted in ('*', ['*'], ['CloudDocuments']):
            self.assertTrue(predicate(['CloudDocuments'], permitted))
        for permitted in (None, [], ['CloudKit'], 'CloudKit', [7]):
            self.assertFalse(predicate(['CloudDocuments'], permitted))
        self.assertFalse(predicate(['CloudDocuments', 'CloudKit'], '*'))
        self.assertFalse(predicate([], '*'))

if __name__ == '__main__':
    unittest.main()
