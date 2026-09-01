#!/usr/bin/env python3
"""Render the tracked repository rulesets from the fleet policy."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "configs/github/fleet-ruleset-policy.json"
OUTPUTS = {
    REPO_ROOT / "configs/github/repo-ruleset.json": "active",
    REPO_ROOT / "configs/github/repo-ruleset-active.json": "active",
    REPO_ROOT / "configs/github/repo-ruleset-evaluate.json": "evaluate",
}
EXPECTED_RULE_TYPES = {
    "deletion",
    "merge_queue",
    "non_fast_forward",
    "pull_request",
    "required_linear_history",
    "required_signatures",
    "required_status_checks",
}
PARAMETERLESS_RULE_TYPES = {
    "deletion",
    "non_fast_forward",
    "required_linear_history",
    "required_signatures",
}


class PolicyError(ValueError):
    """The canonical policy is incomplete or internally inconsistent."""


def _declared_repositories() -> list[str]:
    text = (REPO_ROOT / ".gitmodules").read_text(encoding="utf-8")
    repositories = {"Odysseus"}
    for match in re.finditer(
        r"^\s*url\s*=\s*\S+/([^/\s]+?)(?:\.git)?\s*$", text, re.MULTILINE
    ):
        repositories.add(match.group(1))
    return sorted(repositories)


def _single_rule(rules: list[dict[str, Any]], rule_type: str) -> dict[str, Any]:
    matches = [rule for rule in rules if rule.get("type") == rule_type]
    if len(matches) != 1:
        raise PolicyError(f"policy must define exactly one {rule_type} rule")
    return matches[0]


def _exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise PolicyError(f"{label} has missing or unknown fields")
    return value


def _nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PolicyError(f"{label} must be a non-empty string")
    return value


def _boolean(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise PolicyError(f"{label} must be a boolean")
    return value


def _integer(
    value: Any, label: str, minimum: int = 0, maximum: int | None = None
) -> int:
    if (
        type(value) is not int
        or value < minimum
        or (maximum is not None and value > maximum)
    ):
        bounds = f"{minimum}..{maximum}" if maximum is not None else f">= {minimum}"
        raise PolicyError(f"{label} must be an integer in {bounds}")
    return value


def _enum(value: Any, allowed: set[str], label: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise PolicyError(f"{label} must be one of {sorted(allowed)}")
    return value


def _string_list(value: Any, label: str, *, nonempty: bool = False) -> list[str]:
    if not isinstance(value, list) or (nonempty and not value):
        raise PolicyError(f"{label} must be a{' non-empty' if nonempty else ''} list")
    for item in value:
        _nonempty_string(item, f"{label} entry")
    if len(value) != len(set(value)):
        raise PolicyError(f"{label} contains duplicates")
    return value


def _validate_reviewer(value: Any, label: str) -> None:
    reviewer = _exact_keys(value, {"type", "id"}, label)
    _enum(
        reviewer["type"],
        {"IntegrationInstallation", "RepositoryRole", "Team", "User"},
        f"{label}.type",
    )
    _integer(reviewer["id"], f"{label}.id")


def _validate_policy_schema(policy: dict[str, Any]) -> None:
    settings = _exact_keys(
        policy["repository_settings"],
        {
            "allow_auto_merge",
            "allow_merge_commit",
            "allow_rebase_merge",
            "allow_squash_merge",
            "allow_update_branch",
            "delete_branch_on_merge",
            "web_commit_signoff_required",
        },
        "repository settings",
    )
    for field, value in settings.items():
        _boolean(value, f"repository_settings.{field}")

    ruleset = _exact_keys(
        policy["ruleset"],
        {"name", "target", "conditions", "bypass_actors", "rules"},
        "ruleset model",
    )
    _nonempty_string(ruleset["name"], "ruleset.name")
    _nonempty_string(ruleset["target"], "ruleset.target")
    conditions = _exact_keys(ruleset["conditions"], {"ref_name"}, "conditions")
    ref_name = _exact_keys(
        conditions["ref_name"], {"include", "exclude"}, "conditions.ref_name"
    )
    _string_list(ref_name["include"], "conditions.ref_name.include", nonempty=True)
    _string_list(ref_name["exclude"], "conditions.ref_name.exclude")

    bypass_actors = ruleset["bypass_actors"]
    if not isinstance(bypass_actors, list):
        raise PolicyError("ruleset.bypass_actors must be a list")
    for index, value in enumerate(bypass_actors):
        actor = _exact_keys(
            value,
            {"actor_id", "actor_type", "bypass_mode"},
            f"bypass actor {index}",
        )
        _integer(actor["actor_id"], f"bypass actor {index}.actor_id")
        _enum(
            actor["actor_type"],
            {
                "DeployKey",
                "Integration",
                "OrganizationAdmin",
                "RepositoryRole",
                "Team",
                "User",
            },
            f"bypass actor {index}.actor_type",
        )
        _enum(
            actor["bypass_mode"],
            {"always", "exempt", "pull_request"},
            f"bypass actor {index}.bypass_mode",
        )

    rules = ruleset["rules"]
    if not isinstance(rules, list) or len(rules) != len(EXPECTED_RULE_TYPES):
        raise PolicyError("ruleset must contain the complete common rule set")
    if any(not isinstance(rule, dict) for rule in rules):
        raise PolicyError("every ruleset rule must be an object")
    rule_types = [rule.get("type") for rule in rules]
    if set(rule_types) != EXPECTED_RULE_TYPES or len(rule_types) != len(set(rule_types)):
        raise PolicyError("ruleset contains missing, duplicate, or unknown rules")
    for rule_type in PARAMETERLESS_RULE_TYPES:
        _exact_keys(_single_rule(rules, rule_type), {"type"}, f"{rule_type} rule")

    pull_request = _exact_keys(
        _single_rule(rules, "pull_request"), {"type", "parameters"}, "pull_request rule"
    )
    pull_parameters = _exact_keys(
        pull_request["parameters"],
        {
            "allowed_merge_methods",
            "dismiss_stale_reviews_on_push",
            "dismissal_restriction",
            "require_code_owner_review",
            "require_extra_approval_for_unattributed_changes",
            "require_last_push_approval",
            "required_approving_review_count",
            "required_review_thread_resolution",
            "required_reviewers",
        },
        "pull_request parameters",
    )
    allowed_merge_methods = _string_list(
        pull_parameters["allowed_merge_methods"],
        "pull_request.allowed_merge_methods",
        nonempty=True,
    )
    if any(method not in {"merge", "rebase", "squash"} for method in allowed_merge_methods):
        raise PolicyError("pull_request.allowed_merge_methods contains an invalid method")
    for field in (
        "dismiss_stale_reviews_on_push",
        "require_code_owner_review",
        "require_extra_approval_for_unattributed_changes",
        "require_last_push_approval",
        "required_review_thread_resolution",
    ):
        _boolean(pull_parameters[field], f"pull_request.{field}")
    _integer(
        pull_parameters["required_approving_review_count"],
        "pull_request.required_approving_review_count",
        0,
        6,
    )
    dismissal = _exact_keys(
        pull_parameters["dismissal_restriction"],
        {"allowed_actors", "enabled"},
        "pull_request.dismissal_restriction",
    )
    _boolean(dismissal["enabled"], "pull_request.dismissal_restriction.enabled")
    if not isinstance(dismissal["allowed_actors"], list):
        raise PolicyError("pull_request dismissal actors must be a list")
    for index, actor in enumerate(dismissal["allowed_actors"]):
        _validate_reviewer(actor, f"pull_request dismissal actor {index}")
    reviewers = pull_parameters["required_reviewers"]
    if not isinstance(reviewers, list):
        raise PolicyError("pull_request.required_reviewers must be a list")
    for index, value in enumerate(reviewers):
        reviewer = _exact_keys(
            value,
            {"reviewer", "minimum_approvals", "file_patterns"},
            f"required reviewer {index}",
        )
        _validate_reviewer(reviewer["reviewer"], f"required reviewer {index}.reviewer")
        _integer(
            reviewer["minimum_approvals"],
            f"required reviewer {index}.minimum_approvals",
            0,
            10,
        )
        _string_list(
            reviewer["file_patterns"], f"required reviewer {index}.file_patterns"
        )

    queue = _exact_keys(
        _single_rule(rules, "merge_queue"), {"type", "parameters"}, "merge_queue rule"
    )
    queue_parameters = _exact_keys(
        queue["parameters"],
        {
            "check_response_timeout_minutes",
            "grouping_strategy",
            "max_entries_to_build",
            "max_entries_to_merge",
            "merge_method",
            "min_entries_to_merge",
            "min_entries_to_merge_wait_minutes",
        },
        "merge_queue parameters",
    )
    _integer(
        queue_parameters["check_response_timeout_minutes"],
        "merge_queue.check_response_timeout_minutes",
        0,
        360,
    )
    for field in ("max_entries_to_build", "max_entries_to_merge", "min_entries_to_merge"):
        _integer(queue_parameters[field], f"merge_queue.{field}", 0, 100)
    _integer(
        queue_parameters["min_entries_to_merge_wait_minutes"],
        "merge_queue.min_entries_to_merge_wait_minutes",
        0,
        360,
    )
    _enum(
        queue_parameters["grouping_strategy"],
        {"ALLGREEN", "HEADGREEN"},
        "merge_queue.grouping_strategy",
    )
    _enum(
        queue_parameters["merge_method"],
        {"MERGE", "REBASE", "SQUASH"},
        "merge_queue.merge_method",
    )

    required = _exact_keys(
        _single_rule(rules, "required_status_checks"),
        {"type", "parameters"},
        "required_status_checks rule",
    )
    required_parameters = _exact_keys(
        required["parameters"],
        {
            "strict_required_status_checks_policy",
            "do_not_enforce_on_create",
            "required_status_checks",
        },
        "required_status_checks parameters",
    )
    _boolean(
        required_parameters["strict_required_status_checks_policy"],
        "required_status_checks.strict_required_status_checks_policy",
    )
    _boolean(
        required_parameters["do_not_enforce_on_create"],
        "required_status_checks.do_not_enforce_on_create",
    )
    checks = required_parameters["required_status_checks"]
    if not isinstance(checks, list) or not checks:
        raise PolicyError("required_status_checks must be a non-empty list")
    for index, value in enumerate(checks):
        check = _exact_keys(
            value, {"context", "integration_id"}, f"required status check {index}"
        )
        _nonempty_string(check["context"], f"required status check {index}.context")
        _integer(
            check["integration_id"], f"required status check {index}.integration_id", 1
        )
    contexts = [check["context"] for check in checks]
    if len(contexts) != len(set(contexts)):
        raise PolicyError("required status check contexts must be unique")


def _load_policy(policy_path: Path | None = None) -> dict[str, Any]:
    if policy_path is None:
        policy_path = POLICY_PATH
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PolicyError(f"cannot read canonical policy: {error}") from error

    if not isinstance(policy, dict) or set(policy) != {
        "schema_version",
        "organization",
        "repositories",
        "repository_settings",
        "ruleset",
    }:
        raise PolicyError("canonical policy has missing or unknown top-level fields")
    if type(policy["schema_version"]) is not int or policy["schema_version"] != 1:
        raise PolicyError("unsupported canonical policy schema version")
    _nonempty_string(policy["organization"], "organization")
    if policy["repositories"] != _declared_repositories():
        raise PolicyError("policy fleet must equal Odysseus plus .gitmodules")
    if len(policy["repositories"]) != len(set(policy["repositories"])):
        raise PolicyError("policy fleet contains duplicate repositories")

    _validate_policy_schema(policy)
    return policy


def _render(policy: dict[str, Any], enforcement: str) -> dict[str, Any]:
    ruleset = policy["ruleset"]
    return {
        "name": ruleset["name"],
        "target": ruleset["target"],
        "enforcement": enforcement,
        "conditions": copy.deepcopy(ruleset["conditions"]),
        "bypass_actors": copy.deepcopy(ruleset["bypass_actors"]),
        "rules": copy.deepcopy(ruleset["rules"]),
    }


def _serialized(payload: dict[str, Any]) -> str:
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def _check(policy: dict[str, Any]) -> int:
    drifted: list[str] = []
    for path, enforcement in OUTPUTS.items():
        expected = _render(policy, enforcement)
        try:
            actual = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            drifted.append(str(path.relative_to(REPO_ROOT)))
            continue
        if actual != expected:
            drifted.append(str(path.relative_to(REPO_ROOT)))
    if drifted:
        print("ruleset artifacts differ from canonical policy:", file=sys.stderr)
        for path in drifted:
            print(f"  - {path}", file=sys.stderr)
        return 1
    return 0


def _write(policy: dict[str, Any]) -> None:
    for path, enforcement in OUTPUTS.items():
        path.write_text(_serialized(_render(policy, enforcement)), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--policy-file",
        type=Path,
        default=POLICY_PATH,
        help="read policy from this immutable input snapshot",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check", action="store_true", help="fail if tracked artifacts drift"
    )
    mode.add_argument("--write", action="store_true", help="rewrite tracked artifacts")
    mode.add_argument(
        "--enforcement",
        choices=("active", "evaluate"),
        help="render one payload to stdout",
    )
    args = parser.parse_args()

    try:
        policy = _load_policy(args.policy_file)
    except PolicyError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    if args.check:
        return _check(policy)
    if args.write:
        _write(policy)
        return 0
    print(_serialized(_render(policy, args.enforcement)), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
