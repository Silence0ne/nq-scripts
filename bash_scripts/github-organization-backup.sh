#!/usr/bin/env bash
#
# clone-all-repos.sh
#
# Usage:
#   ./clone-all-repos.sh <github-url-or-username> [parent-dir]
#
# Examples:
#   ./clone-all-repos.sh https://github.com/torvalds
#   ./clone-all-repos.sh torvalds ~/Downloads
#
# Output structure:
#   <parent-dir>/<account>_<YYYYMMDD_HHMMSS>/            Main directory (active repos)
#   <parent-dir>/<account>_<YYYYMMDD_HHMMSS>/archived/   Archived repos (separate from others)
#   <parent-dir>/<account>_<YYYYMMDD_HHMMSS>.zip         Final compressed file of the entire folder
#
# Configurable environment variables:
#   GITHUB_TOKEN     GitHub access token (optional; if set, it will be used, otherwise
#                    the script continues with public/no-token access)
#   CLONE_PROTOCOL   ssh or https (default: https)
#   PARALLEL_JOBS    Number of parallel clones (default: 4)

set -uo pipefail

CLONE_PROTOCOL="${CLONE_PROTOCOL:-https}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
API_BASE="https://api.github.com"

# ---------- Input validation ----------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <github-url-or-username> [parent-dir]" >&2
    exit 1
fi

RAW_INPUT="$1"
PARENT_DIR="${2:-.}"


PARENT_DIR="${PARENT_DIR%/}"

if [[ "$CLONE_PROTOCOL" != "https" && "$CLONE_PROTOCOL" != "ssh" ]]; then
    echo "Error: CLONE_PROTOCOL must be ssh or https (current value: $CLONE_PROTOCOL)" >&2
    exit 1
fi

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_JOBS" -lt 1 ]]; then
    echo "Error: PARALLEL_JOBS must be a positive integer." >&2
    exit 1
fi

# ---------- Dependency check: only curl (as per decision) ----------
if ! command -v curl &>/dev/null; then
    echo "curl is not installed"
    exit 1
fi

# ---------- Extract account name from link or raw input ----------
extract_account() {
    local input="$1"
    input="${input#http://}"
    input="${input#https://}"
    input="${input#www.}"
    if [[ "$input" == github.com/* ]]; then
        input="${input#github.com/}"
    fi
    input="${input%%[/?#]*}"
    echo "$input"
}

ACCOUNT="$(extract_account "$RAW_INPUT")"

if [[ -z "$ACCOUNT" ]]; then
    echo "Error: Could not extract account name from input: $RAW_INPUT" >&2
    exit 1
fi

# ---------- API request (with token if available, otherwise without) ----------
api_get() {
    local url="$1"
    if [[ -n "$GITHUB_TOKEN" ]]; then
        curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github+json" \
             "$url"
    else
        curl -s -H "Accept: application/vnd.github+json" "$url"
    fi
}

# ---------- Detect account type: user or organization ----------
echo "Checking account type for '$ACCOUNT'..."
ACCOUNT_INFO="$(api_get "$API_BASE/users/$ACCOUNT")"
ACCOUNT_TYPE="$(echo "$ACCOUNT_INFO" | jq -r '.type // empty' 2>/dev/null)"

if [[ -z "$ACCOUNT_TYPE" ]]; then
    echo "Error: Account '$ACCOUNT' not found or rate limit has been triggered." >&2
    echo "$ACCOUNT_INFO" | jq -r '.message // .' 2>/dev/null >&2
    exit 1
fi

if [[ "$ACCOUNT_TYPE" == "Organization" ]]; then
    REPOS_ENDPOINT="$API_BASE/orgs/$ACCOUNT/repos"
else
    REPOS_ENDPOINT="$API_BASE/users/$ACCOUNT/repos"
fi

echo "Account type: $ACCOUNT_TYPE"

# ---------- Collect list of all repositories with pagination ----------
echo "Fetching repository list..."
PAGE=1
PER_PAGE=100
ALL_REPOS_JSON="[]"

while true; do
    RESPONSE="$(api_get "${REPOS_ENDPOINT}?per_page=${PER_PAGE}&page=${PAGE}&type=all")"

    if echo "$RESPONSE" | jq -e 'type == "object" and has("message")' &>/dev/null; then
        MSG="$(echo "$RESPONSE" | jq -r '.message')"
        echo "Error from GitHub: $MSG" >&2
        [[ "$MSG" == *"rate limit"* ]] && echo "Suggestion: Set GITHUB_TOKEN to increase rate limit." >&2
        exit 1
    fi

    COUNT="$(echo "$RESPONSE" | jq 'length')"
    [[ "$COUNT" -eq 0 ]] && break

    ALL_REPOS_JSON="$(jq -s '.[0] + .[1]' <(echo "$ALL_REPOS_JSON") <(echo "$RESPONSE"))"

    [[ "$COUNT" -lt "$PER_PAGE" ]] && break
    PAGE=$((PAGE + 1))
done

TOTAL="$(echo "$ALL_REPOS_JSON" | jq 'length')"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "No repositories found. (Maybe they're all private and you don't have GITHUB_TOKEN?)"
    exit 0
fi

ARCHIVED_COUNT="$(echo "$ALL_REPOS_JSON" | jq '[.[] | select(.archived == true)] | length')"
ACTIVE_COUNT="$((TOTAL - ARCHIVED_COUNT))"
echo "Total repositories: $TOTAL   (active: $ACTIVE_COUNT, archived: $ARCHIVED_COUNT)"

# ---------- Create output folder: name = account + execution timestamp ----------
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
FOLDER_NAME="${ACCOUNT}_${TIMESTAMP}"
OUTPUT_DIR="${PARENT_DIR}/${FOLDER_NAME}"
ARCHIVED_DIR="${OUTPUT_DIR}/archived"

mkdir -p "$OUTPUT_DIR" "$ARCHIVED_DIR"

LOG_FILE="$OUTPUT_DIR/clone-log.txt"
SUCCESS_LOG="$OUTPUT_DIR/success.txt"
FAILED_LOG="$OUTPUT_DIR/failed.txt"
: > "$LOG_FILE"
: > "$SUCCESS_LOG"
: > "$FAILED_LOG"

echo "Output directory: $OUTPUT_DIR"
echo "Protocol: $CLONE_PROTOCOL   |   Parallel clones: $PARALLEL_JOBS"
echo "-----------------------------------------------------"

# ---------- Function to clone/update a single repo ----------
clone_one_repo() {
    local name="$1" ssh_url="$2" clone_url="$3" archived="$4"

    local dest_base="$OUTPUT_DIR"
    [[ "$archived" == "true" ]] && dest_base="$ARCHIVED_DIR"

    local target="$dest_base/$name"
    local url="$clone_url"
    [[ "$CLONE_PROTOCOL" == "ssh" ]] && url="$ssh_url"

    local tag=""
    [[ "$archived" == "true" ]] && tag=" (archived)"

    if [[ -d "$target/.git" ]]; then
        echo "[ INFO ]: $name$tag"
        if git -C "$target" pull --ff-only &>>"$LOG_FILE"; then
            echo "[ INFO ]: $name$tag"
            echo "$name$tag" >> "$SUCCESS_LOG"
        else
            echo "[ INFO ]: $name$tag"
            echo "$name$tag (pull failed)" >> "$FAILED_LOG"
        fi
        return
    fi

    echo "Cloning $name$tag"
    if git clone --quiet "$url" "$target" &>>"$LOG_FILE"; then
        echo "Cloned: $name$tag"
        echo "$name$tag" >> "$SUCCESS_LOG"
    else
        echo "[ Failed ]: $name$tag"
        echo "$name$tag" >> "$FAILED_LOG"
    fi
}

# ---------- Execute clones in parallel (max PARALLEL_JOBS concurrent) ----------
# If one fails, others won't stop; everything is logged in success.txt / failed.txt / clone-log.txt.
active_jobs=0
while IFS=$'\t' read -r name ssh_url clone_url archived; do
    clone_one_repo "$name" "$ssh_url" "$clone_url" "$archived" &
    active_jobs=$((active_jobs + 1))
    if [[ "$active_jobs" -ge "$PARALLEL_JOBS" ]]; then
        wait -n
        active_jobs=$((active_jobs - 1))
    fi
done < <(echo "$ALL_REPOS_JSON" | jq -r '.[] | [.name, .ssh_url, .clone_url, .archived] | @tsv')

wait

# ---------- Summary of clone results ----------
SUCCESS_COUNT="$(wc -l < "$SUCCESS_LOG" | tr -d ' ')"
FAILED_COUNT="$(wc -l < "$FAILED_LOG" | tr -d ' ')"

echo "-----------------------------------------------------"
echo "Clone completed. Successful: $SUCCESS_COUNT   |   Failed: $FAILED_COUNT"
if [[ "$FAILED_COUNT" -gt 0 ]]; then
    echo "List of failed repos: $FAILED_LOG"
fi
echo "Full log: $LOG_FILE"

# ---------- Create zip file of the entire folder, using the same name ----------
if command -v zip &>/dev/null; then
    echo "Creating zip file..."
    if (cd "$PARENT_DIR" && zip -rq "${FOLDER_NAME}.zip" "${FOLDER_NAME}"); then
        echo "Zip file created: ${OUTPUT_DIR}.zip"
    else
        echo "⚠️  Failed to create zip file." >&2
    fi
else
    echo "⚠️  zip command not installed; zip file not created. The cloned folder is still available at:"
    echo "   $OUTPUT_DIR"
fi
