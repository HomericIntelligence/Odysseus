#!/usr/bin/env python3
"""Behavior tests for the current Odysseus console availability boundary."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
CONSOLE_PATH = ROOT / "tools" / "odysseus-console.py"


def load_console():
    spec = importlib.util.spec_from_file_location(
        "odysseus_console_under_test", CONSOLE_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load Odysseus console")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def json_response_body(size: int, research_id: str = "research-1") -> bytes:
    """Return a JSON response with an exact encoded size."""
    empty_body = json.dumps(
        {"id": research_id, "padding": ""}, separators=(",", ":")
    ).encode()
    padding_size = size - len(empty_body)
    if padding_size < 0:
        raise ValueError("requested response size is too small")
    body = json.dumps(
        {"id": research_id, "padding": "x" * padding_size},
        separators=(",", ":"),
    ).encode()
    if len(body) != size:
        raise AssertionError("response fixture has an incorrect size")
    return body


def response_stream(body: bytes) -> mock.MagicMock:
    """Return a context-managed response that reads from a byte stream."""
    response = mock.MagicMock()
    response.__enter__.return_value = response
    response.read.side_effect = io.BytesIO(body).read
    return response


class ConsoleAvailabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.console = load_console()

    def test_watch_mode_fails_before_network_use(self) -> None:
        with (
            mock.patch.object(sys, "argv", [str(CONSOLE_PATH)]),
            mock.patch.object(self.console, "submit_research") as submit,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaisesRegex(SystemExit, "2"),
        ):
            self.console.main()

        submit.assert_not_called()
        self.assertIn("no dedicated least-privilege NATS identity", stderr.getvalue())

    def test_submit_with_watch_fails_before_remote_write(self) -> None:
        with (
            mock.patch.object(
                sys, "argv", [str(CONSOLE_PATH), "submit", "untrusted idea"]
            ),
            mock.patch.object(self.console, "submit_research") as submit,
            self.assertRaisesRegex(SystemExit, "2"),
        ):
            self.console.main()

        submit.assert_not_called()

    def test_submit_without_watch_preserves_http_only_path(self) -> None:
        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console, "submit_research", return_value={"id": "research-1"}
            ) as submit,
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
        ):
            self.console.main()

        submit.assert_called_once_with("idea", "", "")
        self.assertIn("research_id=", stdout.getvalue())
        self.assertNotIn("dispatch:", stdout.getvalue())

    def test_submit_requires_a_returned_intake_id(self) -> None:
        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(self.console, "submit_research", return_value={}),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaisesRegex(SystemExit, "1"),
        ):
            self.console.main()

        self.assertEqual("", stdout.getvalue())
        self.assertIn("no intake id", stderr.getvalue().lower())

    def test_submit_rejects_control_characters_in_returned_intake_id(self) -> None:
        hostile_ids = (
            "research-1\nFORGED: success",
            "research-1\x1b[31mFORGED\x1b[0m",
            "research-1\x1b]0;forged-title\x07",
        )

        for research_id in hostile_ids:
            with (
                self.subTest(research_id=repr(research_id)),
                mock.patch.object(
                    sys,
                    "argv",
                    [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
                ),
                mock.patch.object(
                    self.console,
                    "submit_research",
                    return_value={"id": research_id},
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                self.assertRaisesRegex(SystemExit, "1"),
            ):
                self.console.main()

            self.assertEqual("", stdout.getvalue())
            self.assertNotIn(research_id, stderr.getvalue())
            self.assertIn("invalid intake id", stderr.getvalue().lower())

    def test_submit_rejects_an_oversized_returned_intake_id(self) -> None:
        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console,
                "submit_research",
                return_value={"id": "x" * 257},
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaisesRegex(SystemExit, "1"),
        ):
            self.console.main()

        self.assertEqual("", stdout.getvalue())
        self.assertIn("invalid intake id", stderr.getvalue().lower())

    def test_unsafe_endpoints_are_rejected_before_network_use(self) -> None:
        unsafe_urls = {
            "non-loopback plaintext": "http://192.0.2.10:8081",
            "unsupported scheme": "ftp://nestor.example.test",
            "missing host": "https:///nestor",
            "embedded user": "https://operator@nestor.example.test",
            "embedded password": "https://operator:secret@nestor.example.test",
            "query": "https://nestor.example.test?next=elsewhere",
            "fragment": "https://nestor.example.test#credential",
        }

        for label, url in unsafe_urls.items():
            with (
                self.subTest(label=label),
                mock.patch.object(
                    self.console.urllib.request,
                    "build_opener",
                    side_effect=AssertionError("network path must not be prepared"),
                ) as build_opener,
                self.assertRaises(ValueError),
            ):
                self.console.NESTOR_URL = url
                self.console.submit_research("idea")

            build_opener.assert_not_called()

    def test_plaintext_localhost_name_is_rejected_before_bearer_network_use(
        self,
    ) -> None:
        self.console.NESTOR_URL = "http://localhost:8081"

        with (
            mock.patch.dict(
                self.console.os.environ,
                {"NESTOR_API_KEY": "credential-must-not-leave"},
                clear=True,
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                side_effect=AssertionError("network path must not be prepared"),
            ) as build_opener,
            self.assertRaisesRegex(ValueError, "numeric loopback"),
        ):
            self.console.submit_research("idea")

        build_opener.assert_not_called()

    def test_plaintext_numeric_loopback_literals_are_accepted(self) -> None:
        for url in ("http://127.0.0.1:8081", "http://[::1]:8081"):
            with self.subTest(url=url):
                self.assertEqual(url, self.console.validated_nestor_url(url))

    def test_submit_uses_an_opener_that_refuses_redirects(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        response = response_stream(b'{"id":"research-1"}')
        opener = mock.MagicMock()
        opener.open.return_value = response

        with mock.patch.object(
            self.console.urllib.request,
            "build_opener",
            return_value=opener,
        ) as build_opener:
            result = self.console.submit_research("idea")

        self.assertEqual({"id": "research-1"}, result)
        handlers = build_opener.call_args.args
        self.assertTrue(
            any(
                isinstance(handler, self.console.NoRedirectHandler)
                for handler in handlers
            ),
            "credentialed requests must install a redirect-denying handler",
        )
        proxy_handlers = [
            handler
            for handler in handlers
            if isinstance(handler, self.console.urllib.request.ProxyHandler)
        ]
        self.assertEqual(1, len(proxy_handlers))
        self.assertEqual({}, proxy_handlers[0].proxies)
        opener.open.assert_called_once()

    def test_submit_installs_explicit_tls_trust_despite_ambient_ssl_env(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        response = response_stream(b'{"id":"research-1"}')
        opener = mock.MagicMock()
        opener.open.return_value = response
        ca_bundle = b"exact test trust bundle\n"
        tls_context = mock.MagicMock(spec=self.console.ssl.SSLContext)

        with (
            mock.patch.dict(
                self.console.os.environ,
                {
                    "SSL_CERT_FILE": "/attacker/ca.pem",
                    "SSL_CERT_DIR": "/attacker/certs",
                },
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                return_value=opener,
            ) as build_opener,
            mock.patch.object(
                self.console,
                "_read_bound_ca_bundle",
                return_value=ca_bundle,
            ) as read_ca,
            mock.patch.object(
                self.console.ssl,
                "SSLContext",
                return_value=tls_context,
            ) as context_factory,
        ):
            result = self.console.submit_research("idea")

        self.assertEqual("research-1", result["id"])
        handlers = build_opener.call_args.args
        https_handlers = [
            handler
            for handler in handlers
            if isinstance(handler, self.console.urllib.request.HTTPSHandler)
        ]
        self.assertEqual(1, len(https_handlers))
        self.assertIs(https_handlers[0]._context, tls_context)
        read_ca.assert_called_once()
        context_factory.assert_called_once_with(self.console.ssl.PROTOCOL_TLS_CLIENT)
        tls_context.load_verify_locations.assert_called_once_with(
            cadata=ca_bundle.decode("ascii")
        )

    def test_unavailable_default_ca_trust_fails_before_network_use(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        with (
            mock.patch.dict(self.console.os.environ, {}, clear=True),
            mock.patch.object(
                self.console.ssl,
                "get_default_verify_paths",
                return_value=mock.Mock(openssl_cafile="/trusted/missing-ca.pem"),
            ),
            mock.patch.object(
                self.console,
                "_read_bound_ca_bundle",
                side_effect=ValueError("unavailable"),
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                side_effect=AssertionError("network must not be prepared"),
            ) as build_opener,
            self.assertRaisesRegex(ValueError, "system CA bundle"),
        ):
            self.console.submit_research("idea")

        build_opener.assert_not_called()

    def test_submit_enforces_one_absolute_read_deadline(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        response = response_stream(b'{"id":"research-1"}')

        def slow_read(_size: int) -> bytes:
            time.sleep(0.5)
            return b'{"id":"research-1"}'

        response.read.side_effect = slow_read
        opener = mock.MagicMock()
        opener.open.return_value = response
        started = time.monotonic()
        with (
            mock.patch.object(
                self.console,
                "NESTOR_REQUEST_TIMEOUT_SECONDS",
                0.05,
                create=True,
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            self.assertRaisesRegex(
                self.console.NestorResponseError,
                "deadline",
            ),
        ):
            self.console.submit_research("idea")

        self.assertLess(time.monotonic() - started, 0.3)

    def test_submit_accepts_a_response_at_the_byte_limit(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        limit = self.console.MAX_NESTOR_RESPONSE_BYTES
        response = response_stream(json_response_body(limit))
        opener = mock.MagicMock()
        opener.open.return_value = response

        with mock.patch.object(
            self.console.urllib.request,
            "build_opener",
            return_value=opener,
        ):
            result = self.console.submit_research("idea")

        self.assertEqual("research-1", result["id"])
        response.read.assert_called_once_with(limit + 1)
        request_timeout = opener.open.call_args.kwargs["timeout"]
        self.assertGreater(request_timeout, 0)
        self.assertLessEqual(
            request_timeout,
            self.console.NESTOR_REQUEST_TIMEOUT_SECONDS,
        )

    def test_submit_rejects_an_oversized_http_response(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        limit = self.console.MAX_NESTOR_RESPONSE_BYTES
        oversized_bodies = {
            "before JSON validation": b"{" + (b"x" * limit),
            "before intake ID validation": json_response_body(limit + 1, "invalid\nID"),
        }

        for label, body in oversized_bodies.items():
            with self.subTest(label=label):
                response = response_stream(body)
                opener = mock.MagicMock()
                opener.open.return_value = response

                with (
                    mock.patch.object(
                        self.console.urllib.request,
                        "build_opener",
                        return_value=opener,
                    ),
                    self.assertRaisesRegex(
                        ValueError, rf"response exceeds {limit}-byte limit"
                    ),
                ):
                    self.console.submit_research("idea")

                response.read.assert_called_once_with(limit + 1)

    def test_main_reports_an_oversized_response_as_a_remote_failure(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        limit = self.console.MAX_NESTOR_RESPONSE_BYTES
        secret_id = "FORGED-BODY-SENTINEL\nID"
        response = response_stream(json_response_body(limit + 1, secret_id))
        opener = mock.MagicMock()
        opener.open.return_value = response

        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaises(SystemExit) as stopped,
        ):
            self.console.main()

        self.assertEqual(1, stopped.exception.code)
        self.assertEqual("", stdout.getvalue())
        self.assertIn(f"response exceeds {limit}-byte limit", stderr.getvalue())
        self.assertNotIn("intake id", stderr.getvalue().lower())
        self.assertNotIn(secret_id, stderr.getvalue())

    def test_submit_preserves_malformed_json_failure_below_the_limit(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        response = response_stream(b'{"id":')
        opener = mock.MagicMock()
        opener.open.return_value = response

        with (
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            self.assertRaisesRegex(
                self.console.NestorResponseError, "not valid UTF-8 JSON"
            ) as rejected,
        ):
            self.console.submit_research("idea")

        self.assertIsInstance(rejected.exception.__cause__, json.JSONDecodeError)
        response.read.assert_called_once_with(
            self.console.MAX_NESTOR_RESPONSE_BYTES + 1
        )

    def test_main_reports_an_overlong_json_integer_as_a_remote_failure(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        original_digit_limit = sys.get_int_max_str_digits()
        self.addCleanup(sys.set_int_max_str_digits, original_digit_limit)
        sys.set_int_max_str_digits(4300)
        secret_id = "FORGED-OVERLONG-ID"
        response_body = (
            b'{"number":' + (b"9" * 5000) + b',"id":"' + secret_id.encode() + b'"}'
        )
        self.assertLessEqual(len(response_body), self.console.MAX_NESTOR_RESPONSE_BYTES)
        response = response_stream(response_body)
        opener = mock.MagicMock()
        opener.open.return_value = response

        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaises(SystemExit) as stopped,
        ):
            self.console.main()

        self.assertEqual(1, stopped.exception.code)
        self.assertEqual("", stdout.getvalue())
        self.assertIn("Nestor response failure", stderr.getvalue())
        self.assertNotIn("integer string conversion", stderr.getvalue())
        self.assertNotIn(secret_id, stderr.getvalue())

    def test_main_reports_json_recursion_as_a_remote_failure(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        secret_id = "FORGED-RECURSION-ID"
        response = response_stream(json.dumps({"id": secret_id}).encode())
        opener = mock.MagicMock()
        opener.open.return_value = response
        exit_code = None

        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                return_value=opener,
            ),
            mock.patch.object(
                self.console.json,
                "loads",
                side_effect=RecursionError(f"parser exposed {secret_id}"),
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            try:
                self.console.main()
            except SystemExit as stopped:
                exit_code = stopped.code
            except RecursionError:
                pass

        self.assertEqual(1, exit_code)
        self.assertEqual("", stdout.getvalue())
        self.assertIn("Nestor response failure", stderr.getvalue())
        self.assertNotIn(secret_id, stderr.getvalue())

    def test_main_keeps_local_url_errors_in_the_configuration_path(self) -> None:
        self.console.NESTOR_URL = "http://192.0.2.10:8081"

        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console.urllib.request,
                "build_opener",
                side_effect=AssertionError("network path must not be prepared"),
            ) as build_opener,
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaises(SystemExit) as stopped,
        ):
            self.console.main()

        self.assertEqual(2, stopped.exception.code)
        self.assertEqual("", stdout.getvalue())
        self.assertIn("invalid console configuration", stderr.getvalue().lower())
        build_opener.assert_not_called()

    def test_main_bounds_and_escapes_untrusted_network_error_details(self) -> None:
        hostile_reason = "forged\nline\r\x1b]0;title\x07" + ("💥" * 8192)

        with (
            mock.patch.object(
                sys,
                "argv",
                [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
            ),
            mock.patch.object(
                self.console,
                "submit_research",
                side_effect=self.console.urllib.error.URLError(hostile_reason),
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            self.assertRaises(SystemExit) as stopped,
        ):
            self.console.main()

        rendered = stderr.getvalue()
        self.assertEqual(1, stopped.exception.code)
        self.assertEqual("", stdout.getvalue())
        self.assertLessEqual(len(rendered), 1024)
        self.assertNotIn("forged\nline", rendered)
        self.assertNotIn("\x1b]0;title", rendered)
        self.assertNotIn("\x07", rendered.replace(self.console.RED, ""))
        self.assertIn(r"forged\nline\r\x1b", rendered)

    def test_main_rejects_invalid_url_ports_before_network_use(self) -> None:
        invalid_urls = {
            "nonnumeric port": "https://localhost:not-a-port",
            "out-of-range port": "https://localhost:65536",
        }

        for label, url in invalid_urls.items():
            with self.subTest(label=label):
                self.console.NESTOR_URL = url
                opener = mock.MagicMock()
                opener.open.side_effect = self.console.urllib.error.URLError(
                    "controlled network boundary"
                )

                with (
                    mock.patch.object(
                        sys,
                        "argv",
                        [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
                    ),
                    mock.patch.object(
                        self.console.urllib.request,
                        "build_opener",
                        return_value=opener,
                    ) as build_opener,
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                    mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                    self.assertRaises(SystemExit) as stopped,
                ):
                    self.console.main()

                self.assertEqual(2, stopped.exception.code)
                self.assertEqual("", stdout.getvalue())
                self.assertIn(
                    "invalid console configuration", stderr.getvalue().lower()
                )
                build_opener.assert_not_called()

    def test_main_rejects_invalid_ca_files_before_network_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            directory_path = Path(directory)
            malformed_ca = directory_path / "malformed-ca.pem"
            malformed_ca.write_text("not a certificate\n")
            ca_files = {
                "missing CA file": directory_path / "missing-ca.pem",
                "malformed CA file": malformed_ca,
            }

            for label, ca_file in ca_files.items():
                with self.subTest(label=label):
                    self.console.NESTOR_URL = "https://nestor.example.test"
                    opener = mock.MagicMock()
                    opener.open.side_effect = self.console.urllib.error.URLError(
                        "controlled network boundary"
                    )
                    exit_code = None

                    with (
                        mock.patch.object(
                            sys,
                            "argv",
                            [str(CONSOLE_PATH), "submit", "idea", "--no-watch"],
                        ),
                        mock.patch.dict(
                            self.console.os.environ,
                            {"NESTOR_CA_FILE": str(ca_file)},
                        ),
                        mock.patch.object(
                            self.console.urllib.request,
                            "build_opener",
                            return_value=opener,
                        ) as build_opener,
                        mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                        mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                    ):
                        try:
                            self.console.main()
                        except SystemExit as stopped:
                            exit_code = stopped.code
                        except OSError:
                            pass

                    self.assertEqual(2, exit_code)
                    self.assertEqual("", stdout.getvalue())
                    self.assertIn("NESTOR_CA_FILE", stderr.getvalue())
                    build_opener.assert_not_called()

    def test_explicit_ca_file_must_be_direct_and_bounded(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            target = root / "target.pem"
            target.write_text("not relevant to the path-boundary assertion\n")
            linked = root / "linked.pem"
            linked.symlink_to(target)
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(root, target_is_directory=True)
            oversized = root / "oversized.pem"
            oversized.write_bytes(b"x" * (self.console.MAX_NESTOR_CA_BYTES + 1))

            for label, ca_file in (
                ("symlink", linked),
                ("symlinked parent", linked_parent / target.name),
                ("oversized", oversized),
            ):
                with self.subTest(label=label):
                    with (
                        mock.patch.dict(
                            self.console.os.environ,
                            {"NESTOR_CA_FILE": str(ca_file)},
                        ),
                        mock.patch.object(
                            self.console.urllib.request,
                            "build_opener",
                            side_effect=AssertionError("network must not be prepared"),
                        ) as build_opener,
                        self.assertRaisesRegex(ValueError, "NESTOR_CA_FILE"),
                    ):
                        self.console.submit_research("idea")

                    build_opener.assert_not_called()

    def test_ca_reader_rejects_a_post_open_filename_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            ca_file = root / "ca.pem"
            ca_file.write_bytes(b"bound bytes\n")
            displaced = root / "displaced.pem"
            real_read = self.console.os.read
            swapped = False

            def swap_after_read(descriptor: int, size: int) -> bytes:
                nonlocal swapped
                value = real_read(descriptor, size)
                if value and not swapped:
                    ca_file.rename(displaced)
                    ca_file.write_bytes(b"replacement bytes\n")
                    swapped = True
                return value

            with (
                mock.patch.object(
                    self.console,
                    "_trusted_ca_directory",
                    return_value=True,
                ),
                mock.patch.object(
                    self.console,
                    "_trusted_ca_file",
                    return_value=True,
                ),
                mock.patch.object(
                    self.console.os,
                    "read",
                    side_effect=swap_after_read,
                ),
                self.assertRaisesRegex(ValueError, "changed"),
            ):
                self.console._read_bound_ca_bundle(ca_file)

    def test_ca_reader_rejects_untrusted_writable_storage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            ca_file = root / "ca.pem"
            ca_file.write_bytes(b"untrusted bytes\n")
            with self.assertRaisesRegex(ValueError, "trusted"):
                self.console._read_bound_ca_bundle(ca_file)

            ca_file.chmod(0o666)
            with (
                mock.patch.object(
                    self.console,
                    "_trusted_ca_directory",
                    return_value=True,
                ),
                self.assertRaisesRegex(ValueError, "root-owned"),
            ):
                self.console._read_bound_ca_bundle(ca_file)

    def test_nonfinite_request_deadlines_fail_before_network_use(self) -> None:
        self.console.NESTOR_URL = "https://nestor.example.test"
        for timeout in (float("nan"), float("inf"), float("-inf")):
            with (
                self.subTest(timeout=timeout),
                mock.patch.object(
                    self.console,
                    "NESTOR_REQUEST_TIMEOUT_SECONDS",
                    timeout,
                ),
                mock.patch.object(
                    self.console.urllib.request,
                    "build_opener",
                    side_effect=AssertionError("network must not be prepared"),
                ) as build_opener,
                self.assertRaisesRegex(
                    self.console.NestorResponseError,
                    "deadline",
                ),
            ):
                self.console.submit_research("idea")

            build_opener.assert_not_called()

    def test_redirect_handler_refuses_every_redirect(self) -> None:
        handler = self.console.NoRedirectHandler()

        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code):
                redirected = handler.redirect_request(
                    mock.sentinel.request,
                    mock.sentinel.response,
                    code,
                    "redirect",
                    mock.sentinel.headers,
                    "https://other.example.test/v1/research",
                )
                self.assertIsNone(redirected)


if __name__ == "__main__":
    unittest.main()
