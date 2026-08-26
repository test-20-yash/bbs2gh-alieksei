#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# BBS (Bitbucket Server/DC) -> GitHub parallel migration runner (CLI-friendly)
# Accurate live status bar & counters:
# QUEUE / IN PROGRESS / MIGRATED / FAILED
#
# CSV required columns:
# project-key,project-name,repo,github_org,github_repo,gh_repo_visibility
#
# Env (global settings):
# BBS_BASE_URL
# BBS_USERNAME / BBS_PASSWORD (Bitbucket admin/super admin)
# BBS_SHARED_HOME (shared home path ON the Bitbucket Server host; defaults to
#   $BITBUCKET_HOME/shared when BITBUCKET_HOME is set, else the gh bbs2gh default)
# SSH_USER
# SSH_PRIVATE_KEY_PATH or SSH_PRIVATE_KEY (raw PEM; should NOT be passphrase-protected)
# GH_TOKEN/GH_PAT or gh auth login
#
# Optional for Data Residency:
#   --target-api-url https://api.github.com (default) or regional API endpoint
#
# Optional storage backends (auto-detected):
#   - AWS S3:
#       export AWS_ACCESS_KEY_ID=...
#       export AWS_SECRET_ACCESS_KEY=...
#       export AWS_BUCKET_NAME=...   (or AWS_S3_BUCKET / AWS_BUCKET)
#       export AWS_REGION=...        (or AWS_DEFAULT_REGION)
#   - Azure Blob:
#       export AZURE_STORAGE_CONNECTION_STRING=...
#   - Otherwise defaults to GitHub-owned storage: --use-github-storage
#
# CLI:
# ./1_migration.sh --csv repos.csv --max-concurrent 3 --output output.csv
# Optional: VERBOSE=1 for extra logs
# ------------------------------------------------------------------------------
set -euo pipefail

VERBOSE="${VERBOSE:-0}"

############################################
# CLI args
############################################
MAX_CONCURRENT=3
CSV_PATH="repos.csv"
OUTPUT_PATH="" # empty -> timestamped file

# Data residency / target API URL (default GitHub.com REST API)
TARGET_API_URL="${TARGET_API_URL:-https://api.github.com}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-concurrent) MAX_CONCURRENT="$2"; shift 2;;
    --csv) CSV_PATH="$2"; shift 2;;
    --output) OUTPUT_PATH="$2"; shift 2;;

    # Data residency support (maintain alias for compatibility)
    --target-api-url|--github-api-url) TARGET_API_URL="$2"; shift 2;;

    -*|--*) echo -e "\033[31m[ERROR] Unknown option: $1\033[0m"; exit 1;;
    *) echo -e "\033[31m[ERROR] Unexpected positional arg: $1\033[0m"; exit 1;;
  esac
done

logv() { if [[ "$VERBOSE" == "1" ]]; then echo -e "[DEBUG] $*"; fi; }

############################################
# Validate settings
############################################
if [[ -z "${MAX_CONCURRENT}" || ! "${MAX_CONCURRENT}" =~ ^[0-9]+$ ]]; then
  echo -e "\033[31m[ERROR] --max-concurrent must be an integer\033[0m"; exit 1
fi
if [[ "${MAX_CONCURRENT}" -gt 10 ]]; then
  echo -e "\033[31m[ERROR] Maximum concurrent migrations (${MAX_CONCURRENT}) exceeds the allowed limit of 10.\033[0m"
  exit 1
fi
if [[ "${MAX_CONCURRENT}" -lt 1 ]]; then
  echo -e "\033[31m[ERROR] --max-concurrent must be at least 1.\033[0m"; exit 1
fi

# Normalize CRLF if present (Windows-generated CSV) without rewriting the user's file
if [[ -f "${CSV_PATH}" ]] && LC_ALL=C grep -q $'\r' "${CSV_PATH}" 2>/dev/null; then
  CSV_NORMALIZED="$(mktemp)"
  tr -d '\r' < "${CSV_PATH}" > "${CSV_NORMALIZED}"
  trap 'rm -f "${CSV_NORMALIZED:-}"' EXIT
  CSV_PATH="${CSV_NORMALIZED}"
  echo -e "\033[33m[WARNING] CSV has Windows (CRLF) line endings; using a normalized temporary copy.\033[0m"
fi

if [[ ! -f "${CSV_PATH}" ]]; then
  echo -e "\033[31m[ERROR] CSV file not found: ${CSV_PATH}\033[0m"; exit 1
fi

if [[ -z "${OUTPUT_PATH}" ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_CSV_PATH="repo_migration_output-${timestamp}.csv"
else
  OUTPUT_CSV_PATH="${OUTPUT_PATH}"
fi

if ! command -v gh >/dev/null 2>&1; then
  echo -e "\033[31m[ERROR] GitHub CLI (gh) is not installed. See https://cli.github.com/\033[0m"
  exit 1
fi
logv "gh version: $(gh --version | head -n 1)"
if ! gh bbs2gh --version >/dev/null 2>&1; then
  echo -e "\033[31m[ERROR] Required gh extension 'gh-bbs2gh' is not installed. Install with: gh extension install github/gh-bbs2gh\033[0m"
  exit 1
fi
logv "gh bbs2gh version: $(gh bbs2gh --version 2>/dev/null | head -n 1)"

# gh auth
if ! gh auth status >/dev/null 2>&1; then
  echo -e "\033[31m[ERROR] GitHub CLI not authenticated. Run: gh auth login (or set GH_TOKEN/GH_PAT).\033[0m"
  exit 1
fi

detect_bbs_install() {
  local p launcher bbsHome line detected
  if [[ -n "${BITBUCKET_HOME:-}" && -d "${BITBUCKET_HOME}" ]]; then
    export BITBUCKET_HOME
    echo -e "\033[32m[OK] Bitbucket Server home found via BITBUCKET_HOME: ${BITBUCKET_HOME}\033[0m"
    return 0
  fi
  line="$(ps -ef 2>/dev/null | grep -i '[b]itbucket' | grep -i 'home' | head -n1 || true)"
  if [[ -n "$line" ]]; then
    detected="$(printf '%s\n' "$line" | grep -oE 'bitbucket[._]home=[^[:space:]]+' | head -n1 | sed -E 's/^.*home=//' || true)"
    [[ -z "$detected" ]] && detected="$(printf '%s\n' "$line" | grep -oE '/[^[:space:]]+/bitbucket[^[:space:]]*' | head -n1 || true)"
    if [[ -n "$detected" ]]; then
      export BITBUCKET_HOME="$detected"
      echo -e "\033[32m[OK] Bitbucket Server home auto-detected from running process: ${detected}\033[0m"
      return 0
    fi
  fi
  for p in /var/atlassian/application-data/bitbucket /opt/atlassian/bitbucket; do
    if [[ -d "$p" ]]; then
      export BITBUCKET_HOME="$p"
      echo -e "\033[32m[OK] Bitbucket Server found at default location: ${p}\033[0m"
      return 0
    fi
  done
  launcher="$(command -v start-bitbucket.sh 2>/dev/null || command -v bitbucket 2>/dev/null || true)"
  if [[ -n "$launcher" ]]; then
    bbsHome="$(cd "$(dirname "$launcher")/.." 2>/dev/null && pwd || dirname "$launcher")"
    export BITBUCKET_HOME="$bbsHome"
    echo -e "\033[32m[OK] Bitbucket Server launcher found on PATH: ${launcher} (home: ${bbsHome})\033[0m"
    return 0
  fi
  echo -e "\033[33m[WARNING] Bitbucket Server install not found locally (checked BITBUCKET_HOME, running process, default dirs, PATH). Continuing — remote/SSH migration does not require a local install.\033[0m"
  return 0
}
detect_bbs_install || true

BBS_SHARED_HOME_ARGS=()
resolve_bbs_shared_home() {
  local shared="${BBS_SHARED_HOME:-}"
  if [[ -z "$shared" && -n "${BITBUCKET_HOME:-}" ]]; then
    local home derived
    home="${BITBUCKET_HOME%/}"
    derived="$home"
    [[ "$derived" == */shared ]] || derived="${derived}/shared"
    if [[ -d "${derived}/data/migration/export" ]]; then
      shared="$derived"
    elif [[ -d "${home}/data/migration/export" ]]; then
      shared="$home"
      echo -e "\033[32m[OK] Export directory found directly under BITBUCKET_HOME; using it as the shared home.\033[0m"
    else
      shared="$derived"
    fi
  fi
  if [[ -z "$shared" ]]; then
    echo -e "\033[33m[WARNING] Neither BBS_SHARED_HOME nor BITBUCKET_HOME is set. gh bbs2gh will look for the export archive under its default shared home (/var/atlassian/application-data/bitbucket/shared). Set BBS_SHARED_HOME to the shared home path ON THE BITBUCKET SERVER HOST if your install differs.\033[0m"
    return 0
  fi
  BBS_SHARED_HOME_ARGS=(--bbs-shared-home "$shared")
  echo -e "\033[32m[OK] Bitbucket shared home passed to gh bbs2gh: ${shared}\033[0m"
  return 0
}
resolve_bbs_shared_home

BBS_SSH_EXTRA_ARGS=()
if [[ -n "${BBS_SSH_PORT:-}" ]]; then
  BBS_SSH_EXTRA_ARGS+=(--ssh-port "${BBS_SSH_PORT}")
  echo -e "\033[32m[OK] Using SSH port ${BBS_SSH_PORT} for archive download.\033[0m"
fi
if [[ -n "${BBS_ARCHIVE_DOWNLOAD_HOST:-}" ]]; then
  BBS_SSH_EXTRA_ARGS+=(--archive-download-host "${BBS_ARCHIVE_DOWNLOAD_HOST}")
  echo -e "\033[32m[OK] Downloading the export archive from host ${BBS_ARCHIVE_DOWNLOAD_HOST}.\033[0m"
fi

# BBS env validation
if [[ -z "${BBS_BASE_URL:-}" || -z "${BBS_USERNAME:-}" || -z "${BBS_PASSWORD:-}" ]]; then
  echo -e "\033[31m[ERROR] BBS_BASE_URL, BBS_USERNAME, and BBS_PASSWORD must be set.\033[0m"
  exit 1
fi
BBS_BASE_URL="${BBS_BASE_URL%/}"
logv "Using BBS_BASE_URL=${BBS_BASE_URL}"

if [[ -z "${SSH_USER:-}" ]]; then
  echo -e "\033[31m[ERROR] SSH_USER must be set.\033[0m"
  exit 1
fi

if [[ -z "${SSH_PRIVATE_KEY_PATH:-}" && -z "${SSH_PRIVATE_KEY:-}" ]]; then
  echo -e "\033[31m[ERROR] Provide SSH_PRIVATE_KEY_PATH or SSH_PRIVATE_KEY.\033[0m"
  exit 1
fi

# Target API URL banner
logv "Using TARGET_API_URL=${TARGET_API_URL}"

############################################
# Storage auto-detection (AWS S3 / Azure / GitHub-owned)
############################################
STORAGE_ARGS=()

choose_storage_backend() {
  local has_azure="false"
  local has_aws="false"

  [[ -n "${AZURE_STORAGE_CONNECTION_STRING:-}" ]] && has_azure="true"

  if [[ -n "${AWS_ACCESS_KEY_ID:-}" || -n "${AWS_SECRET_ACCESS_KEY:-}" || -n "${AWS_BUCKET_NAME:-}" || -n "${AWS_S3_BUCKET:-}" || -n "${AWS_BUCKET:-}" || -n "${AWS_REGION:-}" || -n "${AWS_DEFAULT_REGION:-}" ]]; then
    has_aws="true"
  fi

  if [[ "$has_aws" == "true" && "$has_azure" == "true" ]]; then
    echo -e "\033[31m[ERROR] Both AWS and Azure storage variables are set. Please configure only one storage backend.\033[0m"
    return 1
  fi

  if [[ "$has_aws" == "true" ]]; then
    local bucket region
    bucket="${AWS_BUCKET_NAME:-${AWS_S3_BUCKET:-${AWS_BUCKET:-}}}"
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

    if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${bucket:-}" || -z "${region:-}" ]]; then
      echo -e "\033[31m[ERROR] AWS storage detected but missing required variables.\033[0m"
      echo -e "\033[31m[ERROR] Required: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_BUCKET_NAME (or AWS_S3_BUCKET/AWS_BUCKET), AWS_REGION (or AWS_DEFAULT_REGION).\033[0m"
      return 1
    fi

    STORAGE_ARGS=(--aws-bucket-name "${bucket}" --aws-region "${region}")
    logv "Storage backend: AWS S3 (bucket=${bucket}, region=${region})"
    return 0
  fi

  if [[ "$has_azure" == "true" ]]; then
    # Azure backend uses AZURE_STORAGE_CONNECTION_STRING (no extra flags needed)
    STORAGE_ARGS=()
    logv "Storage backend: Azure Blob (AZURE_STORAGE_CONNECTION_STRING detected)"
    return 0
  fi

  # Default: GitHub-owned storage
  STORAGE_ARGS=(--use-github-storage)
  logv "Storage backend: GitHub-owned storage (--use-github-storage)"
  return 0
}

choose_storage_backend

BBS_TLS_ARGS=()
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1)
    BBS_TLS_ARGS+=(--no-ssl-verify)
    echo -e "\033[33m[WARNING] TLS certificate verification is DISABLED (BBS_DISABLE_SSL_VERIFY set). gh bbs2gh will run with --no-ssl-verify.\033[0m"
    ;;
esac

############################################
# CSV helpers (robust parsing)
############################################
# Robust CSV line parser (quoted fields, escaped quotes)
parse_csv_line() {
  local line="$1"
  local -a fields=()
  local field="" in_quotes=false i char next
  for ((i=0; i<${#line}; i++)); do
    char="${line:$i:1}"
    next="${line:$((i+1)):1}"
    if [[ "${char}" == '"' ]]; then
      if [[ "${in_quotes}" == true ]]; then
        if [[ "${next}" == '"' ]]; then
          field+='"'; ((i++))
        else
          in_quotes=false
        fi
      else
        in_quotes=true
      fi
    elif [[ "${char}" == ',' && "${in_quotes}" == false ]]; then
      fields+=("${field}")
      field=""
    else
      field+="${char}"
    fi
  done
  fields+=("${field}")
  printf '%s\n' "${fields[@]}"
}

# Strip a single leading and trailing double-quote if present (no eval)
strip_quotes() {
  local s="$1"
  [[ ${s} == \"* ]] && s="${s#\"}"
  [[ ${s} == *\" ]] && s="${s%\"}"
  printf '%s' "$s"
}

# Header check: require these columns anywhere in header order
REQUIRED_COLUMNS=(project-key project-name repo github_org github_repo gh_repo_visibility)
read -r HEADER_LINE < "${CSV_PATH}"
mapfile -t HEADER_FIELDS < <(parse_csv_line "${HEADER_LINE}")

# Build an index map: name -> position
declare -A COLIDX=()
for idx in "${!HEADER_FIELDS[@]}"; do
  name="${HEADER_FIELDS[$idx]}"
  name="${name%\"}"; name="${name#\"}"
  COLIDX["$name"]="$idx"
done

# Validate required columns exist
missing=()
for col in "${REQUIRED_COLUMNS[@]}"; do
  [[ -n "${COLIDX[$col]:-}" ]] || missing+=("$col")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo -e "\033[31m[ERROR] CSV missing required columns: ${missing[*]}\033[0m"
  echo -e "\033[31m[ERROR] Required: ${REQUIRED_COLUMNS[*]}\033[0m"
  exit 1
fi

############################################
# Status CSV writers
############################################
write_migration_status_csv_header() {
  echo "project-key,project-name,repo,github_org,github_repo,gh_repo_visibility,Migration_Status,Log_File" > "${OUTPUT_CSV_PATH}"
}
append_status_row() {
  # args: projectKey projectName repo github_org github_repo gh_repo_visibility status log_file
  printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "${OUTPUT_CSV_PATH}"
}
update_repo_status_in_csv() {
  # Update by (github_org, github_repo) match
  local target_org="$1" target_repo="$2" new_status="$3" log_file="$4"
  local tmp; tmp="$(mktemp)"
  {
    head -n 1 "${OUTPUT_CSV_PATH}"
    tail -n +2 "${OUTPUT_CSV_PATH}" \
      | while IFS= read -r line; do
          mapfile -t F < <(parse_csv_line "${line}")
          local projectKey; projectKey="$(strip_quotes "${F[0]}")"
          local projectName; projectName="$(strip_quotes "${F[1]}")"
          local repo; repo="$(strip_quotes "${F[2]}")"
          local github_org; github_org="$(strip_quotes "${F[3]}")"
          local github_repo; github_repo="$(strip_quotes "${F[4]}")"
          local gh_repo_visibility; gh_repo_visibility="$(strip_quotes "${F[5]}")"
          local status; status="$(strip_quotes "${F[6]}")"
          local cur_log; cur_log="$(strip_quotes "${F[7]}")"

          if [[ "${github_org}" == "${target_org}" && "${github_repo}" == "${target_repo}" ]]; then
            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
              "${projectKey}" "${projectName}" "${repo}" "${github_org}" "${github_repo}" \
              "${gh_repo_visibility}" "${new_status}" "${log_file}"
          else
            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
              "${projectKey}" "${projectName}" "${repo}" "${github_org}" "${github_repo}" \
              "${gh_repo_visibility}" "${status}" "${cur_log}"
          fi
        done
  } > "${tmp}"
  mv "${tmp}" "${OUTPUT_CSV_PATH}"
}

############################################
# SSH helpers
############################################
resolve_key_path() {
  local input="${1:-}"
  if [[ -n "$input" && "$input" == *"BEGIN"* && "$input" == *"PRIVATE KEY"* ]]; then
    local tmp; tmp="$(mktemp --suffix=.pem)"
    chmod 600 "$tmp"
    printf "%s" "$input" > "$tmp"
    echo "$tmp"
  elif [[ -z "$input" && -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
    echo "$SSH_PRIVATE_KEY_PATH"
  else
    echo "$input"
  fi
}

is_key_encrypted() {
  local key="$1"
  if [[ -f "$key" ]]; then
    if grep -qs 'ENCRYPTED' "$key"; then return 0; fi
    if grep -qs 'BEGIN OPENSSH PRIVATE KEY' "$key" && grep -qs 'bcrypt' "$key"; then return 0; fi
  fi
  return 1
}

############################################
# Migration function (no console noise)
############################################
migrate_repository() {
  local projectKey="$1" projectName="$2" bbsRepoSlug="$3"
  local github_org="$4" github_repo="$5" gh_repo_visibility="$6"
  local log_file="$7"

  {
    printf '[%s] [START] Migration: %s/%s -> %s/%s (gh_repo_visibility: %s)\n' \
      "$(date)" "${projectKey}" "${bbsRepoSlug}" "${github_org}" "${github_repo}" "${gh_repo_visibility}"

    local resolvedKey; resolvedKey="$(resolve_key_path "${SSH_PRIVATE_KEY:-${SSH_PRIVATE_KEY_PATH:-}}")"
    if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
      trap 'rm -f "${resolvedKey}"' RETURN
    fi
    if [[ -z "$resolvedKey" || ! -f "$resolvedKey" ]]; then
      printf '[%s] [ERROR] SSH private key path is invalid or missing: %s\n' "$(date)" "${resolvedKey:-<empty>}"
      return 1
    fi
    if is_key_encrypted "$resolvedKey"; then
      printf '[%s] [ERROR] SSH private key appears ENCRYPTED (passphrase-protected). Use an unencrypted key or preload ssh-agent.\n' "$(date)"
      return 1
    fi

    # Debug prints the exact command with selected storage + target-api-url
    printf '[%s] [DEBUG] gh bbs2gh migrate-repo --bbs-server-url %s --bbs-project %s --bbs-repo %s --github-org %s --github-repo %s %s --ssh-user %s --ssh-private-key %s --target-api-url %s --target-repo-visibility %s\n' \
      "$(date)" "${BBS_BASE_URL}" "${projectKey}" "${bbsRepoSlug}" "${github_org}" "${github_repo}" \
      "$(printf "%q " "${STORAGE_ARGS[@]}")" \
      "${SSH_USER}" "${resolvedKey}" "${TARGET_API_URL}" "${gh_repo_visibility}"

    # Run migration: append output ONLY to log file (no tee to stdout)
    gh bbs2gh migrate-repo \
      --bbs-server-url "${BBS_BASE_URL}" \
      --bbs-project "${projectKey}" \
      --bbs-repo "${bbsRepoSlug}" \
      --github-org "${github_org}" \
      --github-repo "${github_repo}" \
      "${STORAGE_ARGS[@]}" \
      ${BBS_TLS_ARGS[@]+"${BBS_TLS_ARGS[@]}"} \
      ${BBS_SHARED_HOME_ARGS[@]+"${BBS_SHARED_HOME_ARGS[@]}"} \
      ${BBS_SSH_EXTRA_ARGS[@]+"${BBS_SSH_EXTRA_ARGS[@]}"} \
      --ssh-user "${SSH_USER}" \
      --ssh-private-key "${resolvedKey}" \
      --target-api-url "${TARGET_API_URL}" \
      --target-repo-visibility "${gh_repo_visibility}" \
      --use-github-storage \
      --target-uploads-url "https://uploads.cmf-factory.ghe.com"

    # Assess log content
    if grep -q "No operation will be performed" "${log_file}"; then
      printf '[%s] [FAILED] No operation performed - repository may already exist or migration was skipped\n' "$(date)"
      return 1
    fi
    if ! grep -q "State: SUCCEEDED" "${log_file}"; then
      printf '[%s] [FAILED] Migration did not reach SUCCEEDED state\n' "$(date)"
      return 1
    fi

    printf '[%s] [SUCCESS] Migration: %s/%s -> %s/%s\n' \
      "$(date)" "${projectKey}" "${bbsRepoSlug}" "${github_org}" "${github_repo}"
    return 0
  } >> "${log_file}" 2>&1
}

############################################
# Queues and tracking
############################################
declare -A JOB_PIDS=()     # pid -> "projectKey,projectName,repo,github_org,github_repo,gh_repo_visibility"
declare -A JOB_LOGS=()     # pid -> log file
declare -A JOB_REPOKEY=()  # pid -> "github_org,github_repo"
declare -A JOB_LASTLEN=()  # pid -> last printed length

QUEUE=()
MIGRATED=()
FAILED=()
SKIPPED_LARGE=()
NOT_FOUND=()

############################################
# Large-file skip list (from prechecks)
############################################
MIGRATE_LARGE_FILE_REPOS_FLAG=false
case "${MIGRATE_LARGE_FILE_REPOS:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) MIGRATE_LARGE_FILE_REPOS_FLAG=true ;;
esac

declare -A LARGE_FILE_SKIP=()
LARGE_FILE_SKIP_TOTAL=0

load_large_file_skip_list() {
  if [[ "${MIGRATE_LARGE_FILE_REPOS_FLAG}" == true ]]; then
    echo -e "\033[33m[WARNING] MIGRATE_LARGE_FILE_REPOS is enabled - repos containing large files will be migrated. Ensure Git LFS is configured or migration may fail.\033[0m"
    return 0
  fi
  local f="${LARGE_FILE_REPOS_CSV:-}"
  if [[ -z "$f" ]]; then
    f="$(ls -1t large_file_repos-*.csv 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$f" ]]; then
    local d; d="$(dirname "${CSV_PATH}")"
    f="$(ls -1t "${d}"/large_file_repos-*.csv 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$f" || ! -f "$f" ]]; then
    logv "No large-file skip-list found; every repo in the CSV will be attempted."
    return 0
  fi
  local pk rs _rest key
  while IFS=',' read -r pk rs _rest; do
    pk="$(strip_quotes "${pk:-}")"; rs="$(strip_quotes "${rs:-}")"
    [[ -z "$pk" || -z "$rs" || "$pk" == "project_key" ]] && continue
    key="${pk}/${rs}"
    if [[ -z "${LARGE_FILE_SKIP[$key]:-}" ]]; then
      LARGE_FILE_SKIP[$key]=1
      LARGE_FILE_SKIP_TOTAL=$(( LARGE_FILE_SKIP_TOTAL + 1 ))
    fi
  done < "$f"
  if (( LARGE_FILE_SKIP_TOTAL > 0 )); then
    echo -e "\033[33m[WARNING] Large-file skip-list loaded from ${f}: ${LARGE_FILE_SKIP_TOTAL} repo(s) will be skipped. Set MIGRATE_LARGE_FILE_REPOS=true to migrate them anyway.\033[0m"
  fi
  return 0
}
load_large_file_skip_list

############################################
# Repo slug resolution (gh bbs2gh --bbs-repo expects the slug, not the display name)
############################################
BBS_CURL_OPTS=(-sS)
case "${BBS_DISABLE_SSL_VERIFY:-}" in
  [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|1) BBS_CURL_OPTS+=(--insecure) ;;
esac

bbs_auth_header() {
  if [[ -n "${BBS_PAT:-}" ]]; then
    printf 'Authorization: Bearer %s' "$BBS_PAT"
  else
    printf 'Authorization: Basic %s' "$(printf '%s:%s' "${BBS_USERNAME}" "${BBS_PASSWORD}" | base64 | tr -d '\n')"
  fi
}

bbs_urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

declare -A SLUG_CACHE=()

list_project_repos() {
  local projectKey="$1" encP start=0 resp out=""
  encP="$(bbs_urlencode "$projectKey")"
  while :; do
    resp="$(curl "${BBS_CURL_OPTS[@]}" -H "$(bbs_auth_header)" "${BBS_BASE_URL}/rest/api/1.0/projects/${encP}/repos?limit=100&start=${start}" 2>/dev/null || true)"
    [[ -z "$resp" ]] && break
    out+="$(printf '%s' "$resp" | jq -r '.values[]?.slug' 2>/dev/null | tr '\n' ' ')"
    [[ "$(printf '%s' "$resp" | jq -r '.isLastPage' 2>/dev/null)" == "true" ]] && break
    local nextStart; nextStart="$(printf '%s' "$resp" | jq -r '.nextPageStart // empty' 2>/dev/null)"
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done
  printf '%s' "${out:-<could not list>}"
}

WARN_SLUG() { echo -e "\033[33m[WARNING] $*\033[0m" >&2; }

resolve_repo_slug() {
  local projectKey="$1" value="$2"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  projectKey="${projectKey#"${projectKey%%[![:space:]]*}"}"
  projectKey="${projectKey%"${projectKey##*[![:space:]]}"}"
  local key="${projectKey}/${value}"
  if [[ -n "${SLUG_CACHE[$key]:-}" ]]; then
    printf '%s' "${SLUG_CACHE[$key]}"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    printf '%s' "$value"
    return 0
  fi

  local encP encV status probe_body
  probe_body="$(mktemp)"
  encP="$(bbs_urlencode "$projectKey")"
  encV="$(bbs_urlencode "$value")"

  status="$(curl "${BBS_CURL_OPTS[@]}" -o "$probe_body" -w '%{http_code}' \
    -H "$(bbs_auth_header)" \
    "${BBS_BASE_URL}/rest/api/1.0/projects/${encP}/repos/${encV}" 2>/dev/null || echo 000)"
  if [[ "$status" == "200" ]]; then
    local realSlug; realSlug="$(jq -r '.slug // empty' < "$probe_body" 2>/dev/null || true)"
    rm -f "$probe_body"
    if [[ -n "$realSlug" ]]; then
      if [[ "$realSlug" != "$value" ]]; then
        WARN_SLUG "'${value}' is a repository NAME, not a slug. Resolved to slug '${realSlug}' for ${projectKey}."
      fi
      SLUG_CACHE[$key]="$realSlug"
      printf '%s' "$realSlug"
      return 0
    fi
  fi
  rm -f "$probe_body"

  local start=0 resp found=""
  while :; do
    resp="$(curl "${BBS_CURL_OPTS[@]}" -H "$(bbs_auth_header)" \
      "${BBS_BASE_URL}/rest/api/1.0/projects/${encP}/repos?limit=100&start=${start}" 2>/dev/null || true)"
    [[ -z "$resp" ]] && break
    found="$(printf '%s' "$resp" | jq -r --arg n "$value" '.values[]? | select((.name // "") == $n or ((.name // "") | ascii_downcase) == ($n | ascii_downcase)) | .slug' 2>/dev/null | head -n1 || true)"
    [[ -n "$found" ]] && break
    [[ "$(printf '%s' "$resp" | jq -r '.isLastPage' 2>/dev/null)" == "true" ]] && break
    local nextStart; nextStart="$(printf '%s' "$resp" | jq -r '.nextPageStart // empty' 2>/dev/null)"
    [[ -z "$nextStart" ]] && break
    start="$nextStart"
  done

  if [[ -z "$found" ]]; then
    local resp2
    resp2="$(curl "${BBS_CURL_OPTS[@]}" -H "$(bbs_auth_header)" "${BBS_BASE_URL}/rest/api/1.0/repos?projectkey=${encP}&name=${encV}&limit=100" 2>/dev/null || true)"
    if [[ -n "$resp2" ]]; then
      found="$(printf '%s' "$resp2" | jq -r --arg n "$value" --arg pk "$projectKey" '.values[]? | select((((.project.key // "")|ascii_downcase)==($pk|ascii_downcase)) and (((.name // "")|ascii_downcase)==($n|ascii_downcase))) | .slug' 2>/dev/null | head -n1 || true)"
    fi
  fi

  if [[ -n "$found" ]]; then
    echo -e "\033[33m[WARNING] '${value}' is a repository NAME, not a slug. Resolved to slug '${found}' for ${projectKey}.\033[0m" >&2
    SLUG_CACHE[$key]="$found"
    printf '%s' "$found"
    return 0
  fi

  printf '%s' "$value"
  return 1
}

############################################
# Load queue from CSV rows (skip header)
############################################
LINE_NUM=0
while IFS= read -r line; do
  ((LINE_NUM++)) || true
  [[ ${LINE_NUM} -eq 1 ]] && continue
  if [[ -z "${line//[[:space:]]/}" ]]; then
    continue
  fi

  mapfile -t F < <(parse_csv_line "${line}")
  projectKey="${F[${COLIDX[project-key]}]:-}"
  projectName="${F[${COLIDX[project-name]}]:-}"
  repoSlug="${F[${COLIDX[repo]}]:-}"
  github_org="${F[${COLIDX[github_org]}]:-}"
  github_repo="${F[${COLIDX[github_repo]}]:-}"
  gh_repo_visibility="${F[${COLIDX[gh_repo_visibility]}]:-}"

  # Trim quotes
  projectKey="$(strip_quotes "$projectKey")"
  projectName="$(strip_quotes "$projectName")"
  repoSlug="$(strip_quotes "$repoSlug")"
  github_org="$(strip_quotes "$github_org")"
  github_repo="$(strip_quotes "$github_repo")"
  gh_repo_visibility="$(strip_quotes "$gh_repo_visibility")"

  # Basic presence check
  if [[ -z "${projectKey}" || -z "${repoSlug}" || -z "${github_org}" || -z "${github_repo}" || -z "${gh_repo_visibility}" ]]; then
    echo "[WARNING] Skipping malformed line ${LINE_NUM}: missing required columns"
    echo "Ensure project-key, repo, github_org, github_repo, gh_repo_visibility are populated."
    continue
  fi

  if ! repoSlug="$(resolve_repo_slug "${projectKey}" "${repoSlug}")"; then
    echo -e "[31m[ERROR] No repository in ${projectKey} matches the name or slug '${repoSlug}'.[0m"
    echo -e "[31m[ERROR] Available in ${projectKey}: $(list_project_repos "${projectKey}")[0m"
    NOT_FOUND+=("${projectKey}	${projectName}	${repoSlug}	${github_org}	${github_repo}	${gh_repo_visibility}")
    continue
  fi

  if [[ -n "${LARGE_FILE_SKIP["${projectKey}/${repoSlug}"]:-}" ]]; then
    echo "[WARNING] Skipping ${projectKey}/${repoSlug} -> ${github_org}/${github_repo}: contains large file(s) flagged by prechecks."
    SKIPPED_LARGE+=("${projectKey}	${projectName}	${repoSlug}	${github_org}	${github_repo}	${gh_repo_visibility}")
    continue
  fi

  QUEUE+=("${projectKey}	${projectName}	${repoSlug}	${github_org}	${github_repo}	${gh_repo_visibility}")
done < "${CSV_PATH}"

############################################
# Initialize output CSV with Pending
############################################
write_migration_status_csv_header
for item in ${QUEUE[@]+"${QUEUE[@]}"}; do
  IFS=$'\t' read -r projectKey projectName repoSlug github_org github_repo gh_repo_visibility <<< "${item}"
  append_status_row "${projectKey}" "${projectName}" "${repoSlug}" "${github_org}" "${github_repo}" "${gh_repo_visibility}" "Pending" ""
done
for item in ${SKIPPED_LARGE[@]+"${SKIPPED_LARGE[@]}"}; do
  IFS=$'\t' read -r projectKey projectName repoSlug github_org github_repo gh_repo_visibility <<< "${item}"
  append_status_row "${projectKey}" "${projectName}" "${repoSlug}" "${github_org}" "${github_repo}" "${gh_repo_visibility}" "Skipped - Large Files" ""
done
for item in ${NOT_FOUND[@]+"${NOT_FOUND[@]}"}; do
  IFS=$'\t' read -r projectKey projectName repoSlug github_org github_repo gh_repo_visibility <<< "${item}"
  append_status_row "${projectKey}" "${projectName}" "${repoSlug}" "${github_org}" "${github_repo}" "${gh_repo_visibility}" "Failure - Repo Not Found" ""
done

echo "[INFO] Starting migration with ${MAX_CONCURRENT} concurrent jobs..."
echo "[INFO] Processing ${#QUEUE[@]} repositories from: ${CSV_PATH}"
if (( ${#SKIPPED_LARGE[@]} > 0 )); then
  echo "[INFO] Skipping ${#SKIPPED_LARGE[@]} repositories flagged with large files (deferred for Git LFS migration)."
fi
echo "[INFO] Initialized migration status output: ${OUTPUT_CSV_PATH}"

############################################
# Status bar (width stabilization)
############################################
STATUS_LINE_WIDTH=0
show_status_bar() {
  local queue_count=${#QUEUE[@]}
  local progress_count=${#JOB_PIDS[@]}
  local migrated_count=${#MIGRATED[@]}
  local failed_count=${#FAILED[@]}
  local status="QUEUE: ${queue_count} / IN PROGRESS: ${progress_count} / MIGRATED: ${migrated_count} / FAILED: ${failed_count}"
  (( ${#status} > STATUS_LINE_WIDTH )) && STATUS_LINE_WIDTH=${#status}
  printf "\r\033[36m%-${STATUS_LINE_WIDTH}s\033[0m" "${status}"
}

############################################
# Main loop (parallel execution + live counters + log streaming)
############################################
while (( ${#QUEUE[@]} > 0 )) || (( ${#JOB_PIDS[@]} > 0 )); do
  # Start new jobs up to concurrency
  while (( ${#JOB_PIDS[@]} < MAX_CONCURRENT )) && (( ${#QUEUE[@]} > 0 )); do
    repo_info="${QUEUE[0]}"
    QUEUE=("${QUEUE[@]:1}")

    IFS=$'\t' read -r projectKey projectName repoSlug github_org github_repo gh_repo_visibility <<< "${repo_info}"
    log_file="migration-${github_org}-${github_repo}-$(date +%Y%m%d-%H%M%S).txt"

    # Update CSV with "In Progress" + log file
    update_repo_status_in_csv "${github_org}" "${github_repo}" "In Progress" "${log_file}"

    # Start background job: no console output, only log + .result
    (
      if migrate_repository "${projectKey}" "${projectName}" "${repoSlug}" "${github_org}" "${github_repo}" "${gh_repo_visibility}" "${log_file}"; then
        echo "SUCCESS" > "${log_file}.result"
      else
        echo "FAILED" > "${log_file}.result"
      fi
    ) &

    pid=$!
    JOB_PIDS["$pid"]="${repo_info}"
    JOB_LOGS["$pid"]="${log_file}"
    JOB_REPOKEY["$pid"]="${github_org},${github_repo}"
    JOB_LASTLEN["$pid"]=0

    show_status_bar
  done

  # Stream new log content from each job (delta only)
  for pid in "${!JOB_PIDS[@]}"; do
    log="${JOB_LOGS[$pid]}"
    last="${JOB_LASTLEN[$pid]}"
    if [[ -f "${log}" ]]; then
      new_len=$(wc -c < "${log}")
      if (( new_len > last )); then
        delta_bytes=$(( new_len - last ))
        echo "" # newline to clear the status bar before streaming log output
        tail -c "${delta_bytes}" "${log}" | tr -d '\r' | while IFS= read -r l; do
          [[ -n "${l}" ]] && echo "${l}"
        done
        JOB_LASTLEN["$pid"]="${new_len}"
        show_status_bar
      fi
    fi
  done

  # Check completed jobs (ps -p to avoid reused PID false-positives)
  for pid in "${!JOB_PIDS[@]}"; do
    if ! ps -p "${pid}" > /dev/null 2>&1; then
      repo_info="${JOB_PIDS[$pid]}"
      log_file="${JOB_LOGS[$pid]}"
      IFS=',' read -r target_org target_repo <<< "${JOB_REPOKEY[$pid]}"

      result="FAILED"
      if [[ -f "${log_file}.result" ]]; then
        result="$(<"${log_file}.result")"
        rm -f "${log_file}.result"
      fi

      if [[ "${result}" == "SUCCESS" ]]; then
        MIGRATED+=("${repo_info}")
        update_repo_status_in_csv "${target_org}" "${target_repo}" "Success" "${log_file}"
      else
        FAILED+=("${repo_info}")
        update_repo_status_in_csv "${target_org}" "${target_repo}" "Failure" "${log_file}"
      fi

      unset JOB_PIDS["$pid"] JOB_LOGS["$pid"] JOB_REPOKEY["$pid"] JOB_LASTLEN["$pid"]
      show_status_bar
    fi
  done

  sleep 2
done

echo
echo "[INFO] All migrations completed."
total_repos=$(( $(wc -l < "${CSV_PATH}") - 1 ))
echo "[SUMMARY] Total: ${total_repos} / Migrated: ${#MIGRATED[@]} / Failed: ${#FAILED[@]} / Skipped (large files): ${#SKIPPED_LARGE[@]} / Not found in Bitbucket: ${#NOT_FOUND[@]}"

if (( ${#NOT_FOUND[@]} > 0 )); then
  for item in "${NOT_FOUND[@]}"; do
    IFS=$'\t' read -r pk _pn rs _go _gr _vis <<< "${item}"
    echo "::error::repos.csv entry '${pk}/${rs}' matches no repository in Bitbucket - nothing was migrated for it."
  done
fi
echo "[INFO] Wrote migration results with Migration_Status column: ${OUTPUT_CSV_PATH}"

if (( ${#SKIPPED_LARGE[@]} > 0 )); then
  echo "::warning::${#SKIPPED_LARGE[@]} repository(ies) were skipped because they contain large files. Convert them to Git LFS and re-run with MIGRATE_LARGE_FILE_REPOS=true."
  for item in "${SKIPPED_LARGE[@]}"; do
    IFS=$'\t' read -r pk _pn rs gh_org gh_repo _vis <<< "${item}"
    echo "::warning::Skipped (large files): ${gh_org}/${gh_repo} (${pk}/${rs})"
  done
fi

############################################
# 3-way exit code + GitHub Actions annotations
############################################
if (( ${#MIGRATED[@]} == 0 && ${#FAILED[@]} == 0 && ${#SKIPPED_LARGE[@]} > 0 )); then
  echo "::notice::No migrations were attempted - all ${#SKIPPED_LARGE[@]} repository(ies) were deliberately skipped due to large files."
  exit 0

elif (( ${#MIGRATED[@]} == 0 )); then
  echo "::error::No repositories were migrated successfully (0 succeeded out of ${total_repos})."
  for item in ${FAILED[@]+"${FAILED[@]}"}; do
    IFS=$'\t' read -r pk _pn rs gh_org gh_repo _vis <<< "${item}"
    echo "::error::Failed: ${gh_org}/${gh_repo} (${pk}/${rs})"
  done
  exit 1

elif (( ${#FAILED[@]} == 0 )); then
  echo "::notice::All ${#MIGRATED[@]} attempted repositories migrated successfully (${#SKIPPED_LARGE[@]} skipped, ${total_repos} in CSV)"
  exit 0

else
  echo "::warning::Migration completed with partial success: ${#MIGRATED[@]} succeeded, ${#FAILED[@]} failed, ${#SKIPPED_LARGE[@]} skipped out of ${total_repos} total"
  for item in "${FAILED[@]}"; do
    IFS=$'\t' read -r pk _pn rs gh_org gh_repo _vis <<< "${item}"
    echo "::warning::Failed: ${gh_org}/${gh_repo} (${pk}/${rs})"
  done
  exit 0
fi
