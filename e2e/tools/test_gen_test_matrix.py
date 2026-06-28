#!/usr/bin/env python3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_test_matrix as g


def _w(d: str, body: str) -> Path:
    p = Path(d) / "x.sh"
    p.write_text(body, encoding="utf-8")
    return p


class TestParse(unittest.TestCase):
    def test_multi_id_validates_colon(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            r = g.parse(_w(d, "#!/usr/bin/env bash\n"
                             "# Chaos: Concurrent Faults (E08, E09, E13)\n"
                             "# Validates: cascading faults\nset -e\n"))
            self.assertEqual(r["ids"], ["E08", "E09", "E13"])
            self.assertEqual(r["title"], "Concurrent Faults")
            self.assertEqual(r["desc"], "cascading faults")
            self.assertEqual(r["topology"], "Any")

    def test_validates_without_colon(self) -> None:
        # subject-routing.sh real case: no colon after Validates
        with tempfile.TemporaryDirectory() as d:
            r = g.parse(_w(d, "#!/usr/bin/env bash\n"
                             "# Protocol Correctness: Subject Routing (C04, C05, C11, C12)\n"
                             "# Validates NATS subject construction and wildcard matching\n"))
            self.assertEqual(r["desc"], "NATS subject construction and wildcard matching")
            self.assertEqual(r["ids"], ["C04", "C05", "C11", "C12"])

    def test_t4_emdash(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            r = g.parse(_w(d, "#!/usr/bin/env bash\n"
                             "# Chaos: Split-Brain NATS Cluster (E12) — T4 only\n"
                             "# Validates: one partition survives\n"))
            self.assertEqual(r["topology"], "T4")
            self.assertEqual(r["title"], "Split-Brain NATS Cluster")

    def test_measures_and_title_strip(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            r = g.parse(_w(d, "#!/usr/bin/env bash\n"
                             "# Performance: Latency Measurement (B04, B05)\n"
                             "# Measures: task round-trip P50/P95/P99\n"))
            self.assertEqual(r["title"], "Latency Measurement")
            self.assertEqual(r["desc"], "task round-trip P50/P95/P99")
            self.assertEqual(r["topology"], "Any")

    def test_extended_id_stripped_from_title(self) -> None:
        # connection-timeout-graceful.sh: "(A11 extended)" must not leak into title
        with tempfile.TemporaryDirectory() as d:
            r = g.parse(_w(d, "#!/usr/bin/env bash\n"
                             "# Fault Tolerance: Graceful Degradation on NATS Outage (A11 extended)\n"
                             "# Validates: Agamemnon REST API works even when NATS is unreachable\n"))
            self.assertEqual(r["title"], "Graceful Degradation on NATS Outage")
            self.assertIn("A11", r["ids"])

    def test_ids_from_line2_only(self) -> None:
        # IDs mentioned only in line 3 prose must not appear in the id list
        with tempfile.TemporaryDirectory() as d:
            r = g.parse(_w(d, "#!/usr/bin/env bash\n"
                             "# Chaos: Some Test (E01)\n"
                             "# Validates: see also E99 for background\n"))
            self.assertEqual(r["ids"], ["E01"])

    def test_empty_file_returns_empty_fields(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.sh"
            p.write_text("", encoding="utf-8")
            r = g.parse(p)
            self.assertEqual(r["ids"], [])
            self.assertEqual(r["title"], "")
            self.assertEqual(r["desc"], "")
            self.assertEqual(r["topology"], "Any")


class TestValidate(unittest.TestCase):
    def _make_valid_row(self) -> dict:
        return {"file": "x.sh", "category": "chaos",
                "title": "Some Test", "ids": ["E01"],
                "desc": "some property", "topology": "Any"}

    def test_no_errors_on_valid_row(self) -> None:
        self.assertEqual(g.validate([self._make_valid_row()]), [])

    def test_missing_title_is_error(self) -> None:
        row = {**self._make_valid_row(), "title": ""}
        errs = g.validate([row])
        self.assertEqual(len(errs), 1)
        self.assertIn("line 2", errs[0])

    def test_missing_desc_is_error(self) -> None:
        row = {**self._make_valid_row(), "desc": ""}
        errs = g.validate([row])
        self.assertEqual(len(errs), 1)
        self.assertIn("line 3", errs[0])

    def test_both_missing_gives_two_errors(self) -> None:
        row = {**self._make_valid_row(), "title": "", "desc": ""}
        errs = g.validate([row])
        self.assertEqual(len(errs), 2)


class TestSuiteContract(unittest.TestCase):
    def test_all_real_headers_conform(self) -> None:
        self.assertEqual(g.validate(g.all_rows()), [])

    def test_known_totals(self) -> None:
        rows = g.all_rows()
        all_ids = sorted({i for r in rows for i in r["ids"]})
        self.assertEqual(len(rows), 37)
        self.assertEqual(len(all_ids), 65)
        self.assertEqual(sum(1 for r in rows if r["topology"] == "T4"), 7)

    def test_check_passes_on_committed(self) -> None:
        self.assertEqual(g.main(["--check"]), 0)

    def test_validate_passes_on_real_suite(self) -> None:
        self.assertEqual(g.main(["--validate"]), 0)

    def test_all_categories_present(self) -> None:
        rows = g.all_rows()
        cats = {r["category"] for r in rows}
        self.assertEqual(cats, {"chaos", "fault", "perf", "protocol", "security"})


class TestCheckMode(unittest.TestCase):
    def test_check_fails_on_stale_readme(self) -> None:
        # Temporarily swap README to wrong content
        original = g.README.read_text(encoding="utf-8")
        g.README.write_text("# stale content\n", encoding="utf-8")
        try:
            self.assertEqual(g.main(["--check"]), 1)
        finally:
            g.README.write_text(original, encoding="utf-8")

    def test_check_fails_when_readme_missing(self) -> None:
        original = g.README.read_text(encoding="utf-8")
        g.README.unlink()
        try:
            self.assertEqual(g.main(["--check"]), 1)
        finally:
            g.README.write_text(original, encoding="utf-8")

    def test_print_mode_outputs_content(self) -> None:
        import io
        from contextlib import redirect_stdout
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = g.main(["--print"])
        self.assertEqual(rc, 0)
        self.assertIn("E2E Test Coverage Matrix", buf.getvalue())
        self.assertIn("37 tests", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
