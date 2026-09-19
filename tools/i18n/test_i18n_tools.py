#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for the i18n tools, against a throwaway catalog + dictionary.

Points apply_translations.py / xcstrings_io.py at temp files via
RINA_I18N_CATALOG / RINA_I18N_DICT so the real catalog and translations.jsonl
are never touched. Runs each script as a subprocess (matching how the tools
are actually invoked) rather than importing them, since CATALOG/DICT are
read once at import time from the environment.

Usage:  python3 tools/i18n/test_i18n_tools.py
"""
import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
APPLY = os.path.join(HERE, "apply_translations.py")


def base_catalog(strings):
    return {"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"}


class ToolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="i18n-test-")
        self.catalog_path = os.path.join(self.tmp, "Catalog.xcstrings")
        self.dict_path = os.path.join(self.tmp, "translations.jsonl")

    def write_catalog(self, strings):
        with open(self.catalog_path, "w", encoding="utf-8") as fh:
            json.dump(base_catalog(strings), fh, ensure_ascii=False)

    def write_dict(self, lines):
        with open(self.dict_path, "w", encoding="utf-8") as fh:
            for line in lines:
                fh.write(json.dumps(line, ensure_ascii=False) + "\n")

    def run_apply(self, *args):
        env = dict(os.environ)
        env["RINA_I18N_CATALOG"] = self.catalog_path
        env["RINA_I18N_DICT"] = self.dict_path
        result = subprocess.run(
            [sys.executable, APPLY] + list(args),
            cwd=HERE, capture_output=True, text=True, env=env)
        return result

    def read_catalog(self):
        with open(self.catalog_path, encoding="utf-8") as fh:
            return json.load(fh)

    # -- duplicate key rejection -----------------------------------------
    def test_duplicate_key_rejected(self):
        self.write_catalog({"你好": {}})
        self.write_dict([])
        with open(self.dict_path, "w", encoding="utf-8") as fh:
            fh.write('{"k": "你好", "en": "Hello"}\n')
            fh.write('{"k": "other", "en": "Other"}\n')
            fh.write('{"k": "你好", "en": "Hi again"}\n')
        result = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate key", result.stdout + result.stderr)
        self.assertIn(":1 and 3:", (result.stdout + result.stderr).replace(
            self.dict_path, "").replace("translations.jsonl", ""))

    # -- plural write shape -------------------------------------------------
    def test_plural_write_shape(self):
        self.write_catalog({"%lld 个面孔": {}})
        self.write_dict([
            {"k": "%lld 个面孔",
             "en_plural": {"one": "%lld face", "other": "%lld faces"}},
        ])
        result = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        catalog = self.read_catalog()
        loc = catalog["strings"]["%lld 个面孔"]["localizations"]["en"]
        self.assertIn("variations", loc)
        plural = loc["variations"]["plural"]
        self.assertEqual(plural["one"]["stringUnit"]["value"], "%lld face")
        self.assertEqual(plural["other"]["stringUnit"]["value"], "%lld faces")
        self.assertEqual(plural["one"]["stringUnit"]["state"], "translated")

    # -- variation preserved without --force --------------------------------
    def test_variation_preserved_without_force(self):
        self.write_catalog({
            "%lld 个面孔": {
                "localizations": {
                    "en": {"variations": {"plural": {
                        "one": {"stringUnit": {"state": "translated", "value": "%lld face"}},
                        "other": {"stringUnit": {"state": "translated", "value": "%lld faces"}},
                    }}}
                }
            }
        })
        self.write_dict([{"k": "%lld 个面孔", "en": "%lld faces (plain)"}])
        result = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        catalog = self.read_catalog()
        loc = catalog["strings"]["%lld 个面孔"]["localizations"]["en"]
        self.assertIn("variations", loc, "existing plural must survive without --force")

        result = self.run_apply("--force")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("warning", result.stdout.lower())
        catalog = self.read_catalog()
        loc = catalog["strings"]["%lld 个面孔"]["localizations"]["en"]
        self.assertIn("stringUnit", loc)
        self.assertEqual(loc["stringUnit"]["value"], "%lld faces (plain)")

    # -- format-specifier mismatch detection --------------------------------
    def test_specifier_mismatch_detected(self):
        self.write_catalog({"%@ 已连接": {}})
        self.write_dict([{"k": "%@ 已连接", "en": "%lld connected"}])
        result = self.run_apply("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("format-specifier mismatch", result.stdout)
        self.assertIn("%@ 已连接 [en]", result.stdout)

    def test_specifier_reorder_allowed(self):
        self.write_catalog({"%1$@ 距 %2$lld": {}})
        self.write_dict([{"k": "%1$@ 距 %2$lld", "en": "%2$lld from %1$@"}])
        result = self.run_apply("--check")
        self.assertNotIn("format-specifier mismatch", result.stdout)

    def test_plural_one_may_omit_sole_count(self):
        self.write_catalog({"%lld 个面孔": {}})
        self.write_dict([
            {"k": "%lld 个面孔",
             "en_plural": {"one": "a face", "other": "%lld faces"}},
        ])
        result = self.run_apply("--check")
        self.assertNotIn("format-specifier mismatch", result.stdout)

    # -- --check semantics -----------------------------------------------------
    def test_check_fails_while_translations_are_unapplied(self):
        self.write_catalog({"甲": {}})
        self.write_dict([{"k": "甲", "en": "A", "hant": "甲", "ja": "甲"}])
        result = self.run_apply("--check")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("would change", result.stdout)

    def test_check_accepts_catalog_ahead_of_dictionary(self):
        unit = lambda v: {"stringUnit": {"state": "translated", "value": v}}
        self.write_catalog({"甲": {"localizations": {
            "en": unit("A"), "zh-Hant": unit("甲"), "ja": unit("甲")}}})
        self.write_dict([])
        result = self.run_apply("--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not an error", result.stdout)

    # -- --only restricts writes --------------------------------------------
    def test_only_restricts_writes(self):
        self.write_catalog({"甲": {}, "乙": {}})
        self.write_dict([
            {"k": "甲", "en": "A"},
            {"k": "乙", "en": "B"},
        ])
        result = self.run_apply("--only", "甲")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        catalog = self.read_catalog()
        self.assertIn("en", catalog["strings"]["甲"].get("localizations", {}))
        self.assertNotIn("localizations", catalog["strings"]["乙"])


if __name__ == "__main__":
    unittest.main()
