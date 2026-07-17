#!/usr/bin/env python3
"""Behavior assertions for merge-queue workflow permission boundaries."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[2]


def load_workflow(path: str) -> dict[str, Any]:
    """Parse a workflow without YAML 1.1 coercion of keys such as ``on``."""
    workflow = yaml.load((ROOT / path).read_text(), Loader=yaml.BaseLoader)
    if not isinstance(workflow, dict):
        raise AssertionError(f"{path} must contain a YAML mapping")
    return workflow


def job(workflow: dict[str, Any], name: str) -> dict[str, Any]:
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict) or not isinstance(jobs.get(name), dict):
        raise AssertionError(f"job {name!r} is missing")
    return jobs[name]


def permissions(mapping: dict[str, Any]) -> dict[str, str]:
    value = mapping.get("permissions", {})
    if not isinstance(value, dict):
        raise AssertionError("permissions must be a mapping")
    return value


def assert_workflow_defaults() -> None:
    for path in (
        ".github/workflows/_required.yml",
        ".github/workflows/build-images.yml",
        ".github/workflows/install-test.yml",
        ".github/workflows/release.yml",
    ):
        actual = permissions(load_workflow(path))
        assert actual == {"contents": "read"}, (
            f"{path} workflow permissions must be exactly contents: read; "
            f"got {actual!r}"
        )


def assert_build_validation() -> None:
    workflow = load_workflow(".github/workflows/build-images.yml")
    validate = job(workflow, "validate")
    condition = validate.get("if", "")
    for event in ("pull_request", "merge_group", "workflow_dispatch"):
        assert f"github.event_name == '{event}'" in condition, (
            f"build validation condition does not include {event}: {condition!r}"
        )
    assert all(value != "write" for value in permissions(validate).values()), (
        "build validation job must not grant write permissions"
    )


def assert_build_publish() -> None:
    workflow = load_workflow(".github/workflows/build-images.yml")
    publish = job(workflow, "publish")
    assert publish.get("if") == "github.event_name == 'push'", (
        "build publishing must be restricted to push events"
    )
    assert permissions(publish) == {"contents": "read", "packages": "write"}, (
        "build publishing must grant exactly contents:read and packages:write"
    )
    writers = {
        name: permissions(value)
        for name, value in workflow["jobs"].items()
        if isinstance(value, dict)
        and any(permission == "write" for permission in permissions(value).values())
    }
    assert writers == {"publish": {"contents": "read", "packages": "write"}}, (
        f"unexpected Build Images write grants: {writers!r}"
    )


def assert_release_publish() -> None:
    workflow = load_workflow(".github/workflows/release.yml")
    publish = job(workflow, "publish")
    condition = publish.get("if", "")
    assert "github.event_name == 'push'" in condition
    assert "startsWith(github.ref, 'refs/tags/')" in condition
    assert permissions(publish) == {"contents": "write"}, (
        "release publishing must grant exactly contents:write"
    )
    writers = {
        name: permissions(value)
        for name, value in workflow["jobs"].items()
        if isinstance(value, dict)
        and any(permission == "write" for permission in permissions(value).values())
    }
    assert writers == {"publish": {"contents": "write"}}, (
        f"unexpected Release write grants: {writers!r}"
    )


def assert_release_validation() -> None:
    workflow = load_workflow(".github/workflows/release.yml")
    release = job(workflow, "release")
    assert all(value != "write" for value in permissions(release).values()), (
        "release validation job must not grant write permissions"
    )


CHECKS = {
    "workflow-defaults": assert_workflow_defaults,
    "build-validation": assert_build_validation,
    "build-publish": assert_build_publish,
    "release-publish": assert_release_publish,
    "release-validation": assert_release_validation,
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("check", choices=CHECKS)
    args = parser.parse_args()
    CHECKS[args.check]()


if __name__ == "__main__":
    main()
