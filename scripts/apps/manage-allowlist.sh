#!/usr/bin/env bash
# =============================================================================
# manage-allowlist.sh — App allowlist management
# =============================================================================
# Manage the list of approved apps included in air-gapped export bundles.
#
# Usage:
#   ./scripts/apps/manage-allowlist.sh <command> [app_id]
#
# Commands:
#   list          List all approved apps in the allowlist
#   status        Show approval status for all synced apps
#   add <id>      Add an app to the allowlist
#   remove <id>   Remove an app from the allowlist
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
ALLOWLIST="${PROJECT_DIR}/config/app-allowlist.txt"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

require_allowlist() {
    [ -f "${ALLOWLIST}" ] || error "Allowlist not found: ${ALLOWLIST}"
}

# Strip comments and blank lines from allowlist
read_allowlist() {
    grep -v '^\s*#' "${ALLOWLIST}" | grep -v '^\s*$' || true
}

cmd_list() {
    require_allowlist
    local apps
    apps="$(read_allowlist)"
    if [ -z "${apps}" ]; then
        echo "Allowlist is empty — all synced apps are included in exports."
        echo "Add apps with: $(basename "$0") add <app_id>"
    else
        echo "Approved apps ($(echo "${apps}" | wc -l | tr -d ' ') total):"
        echo "${apps}" | sort | while read -r id; do
            echo "  ${id}"
        done
    fi
}

cmd_add() {
    local app_id="${1:-}"
    [ -n "${app_id}" ] || error "Usage: $(basename "$0") add <app_id>"
    require_allowlist

    # Check if already present
    if read_allowlist | grep -qx "${app_id}"; then
        info "'${app_id}' is already in the allowlist."
        exit 0
    fi

    # Append after the last non-comment line
    printf '\n%s\n' "${app_id}" >> "${ALLOWLIST}"
    info "Added '${app_id}' to allowlist."
}

cmd_remove() {
    local app_id="${1:-}"
    [ -n "${app_id}" ] || error "Usage: $(basename "$0") remove <app_id>"
    require_allowlist

    if ! read_allowlist | grep -qx "${app_id}"; then
        info "'${app_id}' is not in the allowlist."
        exit 0
    fi

    # Remove the line — use portable in-place edit
    local tmp
    tmp="$(mktemp)"
    grep -v "^[[:space:]]*${app_id}[[:space:]]*$" "${ALLOWLIST}" > "${tmp}" || true
    mv "${tmp}" "${ALLOWLIST}"
    info "Removed '${app_id}' from allowlist."
}

cmd_status() {
    require_allowlist

    # Try to query the App Store DB for all synced app IDs
    local db_apps=""
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps postgres \
            2>/dev/null | grep -qE "Up|running"; then
        db_apps="$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
            exec -T postgres psql -U nextcloudappstore nextcloudappstore \
            -t -c "SELECT id FROM nextcloudappstore_core_app ORDER BY id;" \
            2>/dev/null | tr -d ' ' || true)"
    fi

    local approved
    approved="$(read_allowlist)"

    if [ -z "${db_apps}" ]; then
        echo "[WARN]  Could not query DB — showing allowlist only."
        cmd_list
        return
    fi

    local total=0 approved_count=0 not_approved_count=0
    echo ""
    echo "App approval status:"
    echo ""
    printf "  %-40s %s\n" "APP ID" "STATUS"
    printf "  %-40s %s\n" "──────────────────────────────────────" "──────────"
    while IFS= read -r app_id; do
        [ -z "${app_id}" ] && continue
        total=$((total + 1))
        if [ -z "${approved}" ] || echo "${approved}" | grep -qx "${app_id}"; then
            printf "  %-40s %s\n" "${app_id}" "APPROVED"
            approved_count=$((approved_count + 1))
        else
            printf "  %-40s %s\n" "${app_id}" "not approved"
            not_approved_count=$((not_approved_count + 1))
        fi
    done <<< "${db_apps}"

    echo ""
    echo "  Total synced apps : ${total}"
    echo "  Approved          : ${approved_count}"
    echo "  Not approved      : ${not_approved_count}"
    if [ -z "${approved}" ]; then
        echo "  (Empty allowlist — all apps are included)"
    fi
}

COMMAND="${1:-}"
shift || true

case "${COMMAND}" in
    list)           cmd_list ;;
    add)            cmd_add "$@" ;;
    remove)         cmd_remove "$@" ;;
    status)         cmd_status ;;
    "")
        echo "Usage: $(basename "$0") <list|add|remove|status> [app_id]"
        exit 1
        ;;
    *)
        error "Unknown command '${COMMAND}'. Use: list | add | remove | status"
        ;;
esac
