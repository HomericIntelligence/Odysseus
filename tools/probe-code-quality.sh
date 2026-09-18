#!/usr/bin/env bash
#
# probe-code-quality.sh — Discover Code Quality, Code Scanning, Dependabot, and
# Secret Scanning readbacks across HomericIntelligence repositories. Read-only.
#
# Interpret each readback with current official GitHub documentation and
# docs/runbooks/disable-code-quality.md before you select an action. This probe
# does not set a desired state and does not make remote changes.
#
# Usage:
#   tools/probe-code-quality.sh                  # gitlink inventory + Odysseus
#   tools/probe-code-quality.sh --all            # live organization inventory
#   tools/probe-code-quality.sh --output PATH    # also write Markdown to PATH
#
# Requires: gh authenticated with read access to HomericIntelligence.

set -uo pipefail

OUTPUT_PATH=""
ALL_ORG=0

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --output)  OUTPUT_PATH="${2:-}"
               [ -z "$OUTPUT_PATH" ] && { printf 'error: --output requires a path\n' >&2; exit 2; }
               shift 2 ;;
    --all)     ALL_ORG=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { printf 'error: gh CLI not found\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'error: jq not found\n'     >&2; exit 2; }

ORG="HomericIntelligence"

# Build the repository list. Capture discovery before mapfile so a failed
# command cannot become an empty, successful inventory.
repo_names=""
if [ "$ALL_ORG" -eq 1 ]; then
  repo_names=$(gh api --paginate "orgs/${ORG}/repos?per_page=100&type=all" \
    --jq '.[].name') \
    || { printf 'error: could not read the organization repository inventory\n' >&2; exit 2; }
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'error: not inside a git repository\n' >&2; exit 2; }
  [ -f "$REPO_ROOT/.gitmodules" ] && [ ! -L "$REPO_ROOT/.gitmodules" ] \
    || { printf 'error: canonical gitlink inventory is not a direct regular file\n' >&2; exit 2; }
  submodule_inventory=$(git config --file "$REPO_ROOT/.gitmodules" \
    --get-regexp '^submodule\..*\.(path|url)$') \
    || { printf 'error: could not read the canonical gitlink inventory\n' >&2; exit 2; }
  [ -n "$submodule_inventory" ] \
    || { printf 'error: canonical gitlink inventory is empty\n' >&2; exit 2; }

  path_names=()
  path_values=()
  url_names=()
  url_values=()
  url_repos=()
  while IFS=' ' read -r key value extra; do
    if [ -z "$key" ] || [ -z "$value" ] || [ -n "${extra:-}" ]; then
      printf 'error: malformed canonical gitlink inventory\n' >&2
      exit 2
    fi
    case "$key" in
      submodule.*.path)
        name="${key#submodule.}"
        name="${name%.path}"
        if [ "submodule.${name}.path" != "$key" ] \
          || [[ ! "$name" =~ ^[A-Za-z0-9._/-]+$ ]] \
          || [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ ]]; then
          printf 'error: malformed canonical gitlink path inventory\n' >&2
          exit 2
        fi
        case "/$name/" in */./*|*/../*|*//* )
          printf 'error: unsafe canonical gitlink name: %s\n' "$name" >&2
          exit 2
          ;;
        esac
        case "/$value/" in */./*|*/../*|*//* )
          printf 'error: unsafe canonical gitlink path: %s\n' "$value" >&2
          exit 2
          ;;
        esac
        for known_name in ${path_names[@]+"${path_names[@]}"}; do
          [ "$known_name" != "$name" ] || {
            printf 'error: duplicate canonical gitlink name: %s\n' "$name" >&2
            exit 2
          }
        done
        for known_path in ${path_values[@]+"${path_values[@]}"}; do
          [ "$known_path" != "$value" ] || {
            printf 'error: duplicate canonical gitlink path: %s\n' "$value" >&2
            exit 2
          }
        done
        path_names+=("$name")
        path_values+=("$value")
        ;;
      submodule.*.url)
        name="${key#submodule.}"
        name="${name%.url}"
        if [ "submodule.${name}.url" != "$key" ] \
          || [[ ! "$name" =~ ^[A-Za-z0-9._/-]+$ ]]; then
          printf 'error: malformed canonical gitlink URL inventory\n' >&2
          exit 2
        fi
        case "/$name/" in */./*|*/../*|*//* )
          printf 'error: unsafe canonical gitlink URL name: %s\n' "$name" >&2
          exit 2
          ;;
        esac
        if [[ ! "$value" =~ ^https://github\.com/HomericIntelligence/[A-Za-z0-9][A-Za-z0-9._-]*\.git$ ]]; then
          printf 'error: unsupported canonical gitlink URL: %s\n' "$value" >&2
          exit 2
        fi
        repo_name="${value##*/}"
        repo_name="${repo_name%.git}"
        for known_name in ${url_names[@]+"${url_names[@]}"}; do
          [ "$known_name" != "$name" ] || {
            printf 'error: duplicate canonical gitlink URL name: %s\n' "$name" >&2
            exit 2
          }
        done
        for known_url in ${url_values[@]+"${url_values[@]}"}; do
          [ "$known_url" != "$value" ] || {
            printf 'error: duplicate canonical gitlink URL: %s\n' "$value" >&2
            exit 2
          }
        done
        url_names+=("$name")
        url_values+=("$value")
        url_repos+=("$repo_name")
        ;;
      *)
        printf 'error: unsupported canonical gitlink inventory key\n' >&2
        exit 2
        ;;
    esac
  done <<< "$submodule_inventory"

  [ "${#path_names[@]}" -eq "${#url_names[@]}" ] || {
    printf 'error: canonical gitlink path and URL inventories differ\n' >&2
    exit 2
  }
  repo_names="Odysseus"
  path_index=0
  while [ "$path_index" -lt "${#path_names[@]}" ]; do
    name="${path_names[$path_index]}"
    matched_repo=""
    url_index=0
    while [ "$url_index" -lt "${#url_names[@]}" ]; do
      if [ "${url_names[$url_index]}" = "$name" ]; then
        matched_repo="${url_repos[$url_index]}"
        break
      fi
      url_index=$((url_index + 1))
    done
    [ -n "$matched_repo" ] || {
      printf 'error: canonical gitlink URL missing for %s\n' "$name" >&2
      exit 2
    }
    repo_names+=$'\n'"$matched_repo"
    path_index=$((path_index + 1))
  done
fi
REPOS=()
while IFS= read -r repo_name; do
  [ -n "$repo_name" ] || continue
  if [ "${#repo_name}" -gt 100 ] \
    || [[ ! "$repo_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'error: unsafe repository name in inventory\n' >&2
    exit 2
  fi
  for existing_repo in ${REPOS[@]+"${REPOS[@]}"}; do
    if [ "$existing_repo" = "$repo_name" ]; then
      printf 'error: duplicate repository in inventory: %s\n' "$repo_name" >&2
      exit 2
    fi
  done
  REPOS+=("$repo_name")
done <<< "$repo_names"

[ "${#REPOS[@]}" -gt 0 ] || { printf 'error: no repos resolved\n' >&2; exit 2; }

# Probe a boolean inside security_and_analysis.
sa_state() {
  local repo="$1" key="$2" v
  v=$(gh api "repos/${ORG}/${repo}" --jq ".security_and_analysis.${key}.enabled" 2>/dev/null) \
    || { echo 'unavailable'; return; }
  case "$v" in
    true)  echo "enabled" ;;
    false) echo "disabled" ;;
    *)     echo "unavailable" ;;
  esac
}

# Code scanning default-setup readback.
cs_state() {
  local repo="$1" v
  v=$(gh api "repos/${ORG}/${repo}/code-scanning/default-setup" --jq '.state' 2>/dev/null) \
    || { echo "unavailable"; return; }
  case "$v" in
    configured|not-configured) echo "$v" ;;
    *)                         echo "unavailable" ;;
  esac
}

# Code Quality endpoint probe.
cq_state() {
  local repo="$1" body parsed
  body=$(gh api "repos/${ORG}/${repo}/code-quality" 2>/dev/null) \
    || { echo "unavailable"; return; }
  [ -n "$body" ] || { echo "unavailable"; return; }
  if ! parsed=$(jq -r '
    if .enabled    == true  then "enabled"
    elif .enabled  == false then "disabled"
    else "unavailable"
    end
  ' <<< "$body" 2>/dev/null); then
    echo "unavailable"
    return
  fi
  case "$parsed" in
    enabled|disabled|unavailable) echo "$parsed" ;;
    *)                            echo "unavailable" ;;
  esac
}

# Read whether a path is present. A failed request is not proof of absence.
has_file() {
  local repo="$1" path="$2"
  if gh api "repos/${ORG}/${repo}/contents/${path}" >/dev/null 2>&1; then
    echo "present"
  else
    echo "unavailable"
  fi
}

# Build the Markdown report.
report=""
append() { report+="$1"$'\n'; }
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  || { printf 'error: could not produce a report timestamp\n' >&2; exit 2; }
if [ "$ALL_ORG" -eq 1 ]; then
  scope_mode="organization inventory"
else
  scope_mode="canonical gitlink inventory plus Odysseus"
fi

append "# HomericIntelligence — repository security readbacks"
append ""
append "> Generated $generated_at by \`tools/probe-code-quality.sh\`"
append "> Scope: **${#REPOS[@]}** repositories (mode: $scope_mode)"
append ""

append "## Per-repo state"
append ""
append "| Repo | Dependabot sec | Secret scan | Push prot | Code Scanning | Code Quality | CQ config |"
append "|------|----|----|----|----|----|----|"

for repo in "${REPOS[@]}"; do
  d=$(sa_state "$repo" "dependabot_security_updates")
  s=$(sa_state "$repo" "secret_scanning")
  p=$(sa_state "$repo" "secret_scanning_push_protection")
  cs=$(cs_state  "$repo")
  cq=$(cq_state  "$repo")
  cqc=$(has_file "$repo" ".github/codeql/code-quality-config.yml")
  append "| ${repo} | ${d} | ${s} | ${p} | ${cs} | ${cq} | ${cqc} |"
done

append ""
append "## Readback boundaries"
append ""
append "- \`enabled\` and \`disabled\` are explicit API values from this run."
append "- \`unavailable\` means that transport, authorization, endpoint, or schema state did not permit a readback. Do not infer a setting from it."
append "- \`present\` means that this run read the listed repository path."
append "- Consult current official GitHub documentation and \`docs/runbooks/disable-code-quality.md\` before a separately authorized setting change."

if [ -n "$OUTPUT_PATH" ]; then
  if [ -L "$OUTPUT_PATH" ] \
    || { [ -e "$OUTPUT_PATH" ] && [ ! -f "$OUTPUT_PATH" ]; }; then
    printf 'error: unsafe output target: %s\n' "$OUTPUT_PATH" >&2
    exit 2
  fi
  if ! python3 - "$OUTPUT_PATH" "$report" <<'PY'
import hashlib
import os
import secrets
import stat
import sys


destination, report = sys.argv[1:]
payload = report.encode("utf-8")


def required_flag(name):
    value = getattr(os, name, None)
    if value is None:
        raise OSError(f"{name} is required for safe report publication")
    return value


def direct_regular_state(parent_descriptor, name):
    try:
        value = os.lstat(name, dir_fd=parent_descriptor)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise OSError("report target is not one direct regular file")
    return value.st_dev, value.st_ino


def descriptor_digest(descriptor):
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            return digest.digest()
        digest.update(chunk)


def write_all(descriptor, content):
    remaining = memoryview(content)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("report write made no progress")
        remaining = remaining[written:]


source_descriptor = -1
published_descriptor = -1
parent_descriptor = -1
source_name = ""
source_identity = None
source_created = False
try:
    destination = os.path.abspath(destination)
    destination_parent = os.path.dirname(destination)
    destination_name = os.path.basename(destination)
    if destination_name in {"", ".", ".."}:
        raise OSError("invalid report destination name")

    directory_flags = os.O_RDONLY | required_flag("O_DIRECTORY") \
        | required_flag("O_NOFOLLOW") | required_flag("O_CLOEXEC")
    parent_descriptor = os.open(destination_parent, directory_flags)
    parent_state = os.fstat(parent_descriptor)
    if not stat.S_ISDIR(parent_state.st_mode):
        raise OSError("report parent is not a directory")

    def verify_parent_binding():
        rebound_descriptor = os.open(destination_parent, directory_flags)
        try:
            rebound_state = os.fstat(rebound_descriptor)
            if (
                not stat.S_ISDIR(rebound_state.st_mode)
                or (rebound_state.st_dev, rebound_state.st_ino)
                    != (parent_state.st_dev, parent_state.st_ino)
            ):
                raise OSError("report parent changed during publication")
        finally:
            os.close(rebound_descriptor)

    verify_parent_binding()
    initial_destination = direct_regular_state(
        parent_descriptor,
        destination_name,
    )
    source_flags = os.O_RDWR | required_flag("O_NOFOLLOW") \
        | required_flag("O_CLOEXEC")
    create_flags = source_flags | os.O_CREAT | os.O_EXCL
    for _ in range(16):
        candidate = f".odysseus-report-{secrets.token_hex(16)}.tmp"
        try:
            source_descriptor = os.open(
                candidate,
                create_flags,
                0o600,
                dir_fd=parent_descriptor,
            )
        except FileExistsError:
            continue
        source_name = candidate
        source_created = True
        break
    if source_descriptor < 0:
        raise OSError("could not create temporary report")

    source_state = os.fstat(source_descriptor)
    source_identity = source_state.st_dev, source_state.st_ino
    named_source = os.lstat(source_name, dir_fd=parent_descriptor)
    if (
        not stat.S_ISREG(source_state.st_mode)
        or source_state.st_nlink != 1
        or source_identity
            != (named_source.st_dev, named_source.st_ino)
    ):
        raise OSError("temporary report changed before publication")
    write_all(source_descriptor, payload)
    source_digest = descriptor_digest(source_descriptor)
    if source_digest != hashlib.sha256(payload).digest():
        raise OSError("temporary report writeback diverged")
    os.fsync(source_descriptor)

    verify_parent_binding()
    rebound_destination = direct_regular_state(
        parent_descriptor,
        destination_name,
    )
    if rebound_destination != initial_destination:
        raise OSError("report target changed before publication")
    rebound_source = os.lstat(source_name, dir_fd=parent_descriptor)
    if source_identity \
            != (rebound_source.st_dev, rebound_source.st_ino):
        raise OSError("temporary report changed before rename")

    os.replace(
        source_name,
        destination_name,
        src_dir_fd=parent_descriptor,
        dst_dir_fd=parent_descriptor,
    )
    source_created = False
    published_descriptor = os.open(
        destination_name,
        source_flags,
        dir_fd=parent_descriptor,
    )
    published_state = os.fstat(published_descriptor)
    named_destination = os.lstat(destination_name, dir_fd=parent_descriptor)
    if (
        not stat.S_ISREG(published_state.st_mode)
        or published_state.st_nlink != 1
        or (published_state.st_dev, published_state.st_ino)
            != source_identity
        or (published_state.st_dev, published_state.st_ino)
            != (named_destination.st_dev, named_destination.st_ino)
        or descriptor_digest(published_descriptor) != source_digest
    ):
        raise OSError("published report failed descriptor readback")
    os.fsync(published_descriptor)
    verify_parent_binding()
    os.fsync(parent_descriptor)
except (NotImplementedError, OSError, TypeError, ValueError):
    raise SystemExit("error: unsafe report publication target")
finally:
    if source_created and parent_descriptor >= 0 and source_name:
        try:
            named_source = os.lstat(source_name, dir_fd=parent_descriptor)
            if source_identity == (named_source.st_dev, named_source.st_ino):
                os.unlink(source_name, dir_fd=parent_descriptor)
        except FileNotFoundError:
            pass
    for descriptor in (
        published_descriptor,
        source_descriptor,
        parent_descriptor,
    ):
        if descriptor >= 0:
            os.close(descriptor)
PY
  then
    exit 2
  fi
fi

printf '%s' "$report"
