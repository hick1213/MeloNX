"""Tests the actual verifier predicate without reading accounts or profiles."""
import ast
import fnmatch
from pathlib import Path
import unittest
import tempfile

source = Path(__file__).parents[1].joinpath('verify-save-sync-signing.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
functions = [n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name in ('cloud_documents_allowed', 'owned_helpers')]
namespace = {'fnmatch': fnmatch}
exec(compile(ast.Module(body=functions, type_ignores=[]), '<verifier>', 'exec'), namespace)

class SigningTests(unittest.TestCase):
    def test_helper_inventory_ignores_regular_appledouble_metadata_only(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root); plugins = app / 'PlugIns'; plugins.mkdir()
            helper = plugins / 'MeloNXJITHelper.appex'; helper.mkdir()
            (plugins / '._MeloNXJITHelper.appex').write_bytes(b'AppleDouble')
            self.assertEqual(namespace['owned_helpers'](app), [helper])
            (plugins / 'Other.appex').symlink_to(helper, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                namespace['owned_helpers'](app)

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
