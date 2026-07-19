#!/usr/bin/env python3
"""Behavior assertions for merge-queue workflow permission boundaries."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[2]
REQUIRED_CONTEXTS = {
    "lint",
    "unit-tests",
    "integration-tests",
    "security/dependency-scan",
    "security/secrets-scan",
    "build",
    "schema-validation",
    "deps/version-sync",
    "test",
    "install",
    "release",
}
REQUIRED_WORKFLOWS = (
    ".github/workflows/_required.yml",
    ".github/workflows/build-images.yml",
    ".github/workflows/install-test.yml",
    ".github/workflows/release.yml",
)


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
    for path in REQUIRED_WORKFLOWS:
        actual = permissions(load_workflow(path))
        assert actual == {"contents": "read"}, (
            f"{path} workflow permissions must be exactly contents: read; "
            f"got {actual!r}"
        )


def assert_workflow_structure() -> None:
    suppliers: list[str] = []
    supplied_contexts: set[str] = set()
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        relative_path = str(path.relative_to(ROOT))
        workflow = load_workflow(relative_path)
        jobs = workflow.get("jobs", {})
        if not isinstance(jobs, dict):
            raise AssertionError(f"{relative_path} jobs must be a mapping")
        names = {
            value.get("name")
            for value in jobs.values()
            if isinstance(value, dict) and isinstance(value.get("name"), str)
        }
        workflow_contexts = names & REQUIRED_CONTEXTS
        if workflow_contexts:
            suppliers.append(relative_path)
            supplied_contexts.update(workflow_contexts)

    assert tuple(suppliers) == REQUIRED_WORKFLOWS, (
        f"required contexts must be supplied by {REQUIRED_WORKFLOWS!r}; "
        f"got {tuple(suppliers)!r}"
    )
    assert supplied_contexts == REQUIRED_CONTEXTS, (
        f"required workflow context union changed: got {supplied_contexts!r}"
    )

    # Merge-queue checks are served solely by the single fast
    # `merge-queue-smoke` job in merge-queue-smoke.yml. The context-supplying
    # workflows must NOT run for merge groups any more: re-running the full
    # required matrix per queue entry serialized on runner slots (70-90 min
    # per merge). PR-side CI is untouched.
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        relative_path = str(path.relative_to(ROOT))
        triggers = load_workflow(relative_path).get("on")
        if not isinstance(triggers, dict):
            raise AssertionError(f"{relative_path} on must be a mapping")
        if relative_path == ".github/workflows/merge-queue-smoke.yml":
            assert triggers.get("merge_group") == {"types": ["checks_requested"]}, (
                "merge-queue-smoke.yml must handle merge_group checks_requested"
            )
        else:
            assert "merge_group" not in triggers, (
                f"{relative_path} must not run for merge groups; the queue is "
                "served solely by merge-queue-smoke.yml"
            )

    smoke = load_workflow(".github/workflows/merge-queue-smoke.yml")
    smoke_jobs = smoke.get("jobs")
    assert isinstance(smoke_jobs, dict) and list(smoke_jobs) == ["merge-queue-smoke"], (
        "merge-queue-smoke.yml must define exactly one job: merge-queue-smoke"
    )
    assert smoke_jobs["merge-queue-smoke"].get("name") == "merge-queue-smoke"
    assert permissions(smoke) == {"contents": "read"}, (
        "merge-queue-smoke.yml workflow permissions must be exactly contents: read"
    )

    for path in REQUIRED_WORKFLOWS:
        workflow = load_workflow(path)
        jobs = workflow.get("jobs")
        if not isinstance(jobs, dict):
            raise AssertionError(f"{path} jobs must be a mapping")
        checkout_steps = [
            step
            for value in jobs.values()
            if isinstance(value, dict)
            for step in value.get("steps", [])
            if isinstance(step, dict)
            and isinstance(step.get("uses"), str)
            and step["uses"].startswith("actions/checkout@")
        ]
        assert checkout_steps, f"{path} must contain at least one checkout step"
        for step in checkout_steps:
            checkout_with = step.get("with")
            assert isinstance(checkout_with, dict), (
                f"{path} checkout step must configure with.persist-credentials"
            )
            assert checkout_with.get("persist-credentials") == "false", (
                f"{path} checkout must set persist-credentials: false"
            )

    install_workflow = load_workflow(".github/workflows/install-test.yml")
    install_matrix = job(install_workflow, "install-test")
    assert install_matrix.get("if") == "github.event_name != 'merge_group'", (
        "install-test matrix must be excluded from merge groups"
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
    "workflow-structure": assert_workflow_structure,
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
