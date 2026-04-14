#!/usr/bin/env bash
#
# Octo Import — restore a Claude Code environment from an export package
#
# Usage:
#   ./import.sh <export.zip|export-dir> [target-project-dir]
#
# If invoked from inside an extracted export, the first argument is the
# target project directory. If given a .zip, extracts it first.
#
# This script is bundled with every octo export and runs standalone —
# it does NOT require the octo plugin to be installed on the target machine.
#
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
CLEANUP_TEMP=""

# --- Determine if arg1 is a zip, directory, or if we're inside an export ---

resolve_export_and_target() {
    local arg1="${1:-}"
    local arg2="${2:-}"

    # Case 1: arg1 is a .zip file
    if [[ "$arg1" == *.zip && -f "$arg1" ]]; then
        local abs_zip="$(cd "$(dirname "$arg1")" && pwd)/$(basename "$arg1")"
        EXPORT_DIR=$(mktemp -d)
        CLEANUP_TEMP="$EXPORT_DIR"
        echo "Extracting $abs_zip ..."
        unzip -qo "$abs_zip" -d "$EXPORT_DIR"
        # Handle zip containing a single top-level directory
        local contents=("$EXPORT_DIR"/*)
        if [[ ${#contents[@]} -eq 1 && -d "${contents[0]}" ]]; then
            EXPORT_DIR="${contents[0]}"
        fi
        TARGET_DIR="${arg2:-$(pwd)}"
        return
    fi

    # Case 2: arg1 is a directory containing an export
    if [[ -n "$arg1" && -d "$arg1" && -f "$arg1/project/CLAUDE.md" ]]; then
        EXPORT_DIR="$(cd "$arg1" && pwd)"
        TARGET_DIR="${arg2:-$(pwd)}"
        return
    fi

    # Case 3: we're running from inside an extracted export (bundled import.sh)
    local script_dir="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "$script_dir/project/CLAUDE.md" ]]; then
        EXPORT_DIR="$script_dir"
        TARGET_DIR="${arg1:-$(pwd)}"
        return
    fi

    echo "ERROR: Cannot determine export package location."
    echo ""
    echo "Usage:"
    echo "  ./import.sh <export.zip> [target-dir]   Import from zip"
    echo "  ./import.sh <export-dir> [target-dir]    Import from directory"
    echo "  ./import.sh [target-dir]                 If running from inside export"
    exit 1
}

resolve_export_and_target "${1:-}" "${2:-}"
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd || echo "$TARGET_DIR")"

# Cleanup temp dir on exit if we extracted a zip
if [[ -n "$CLEANUP_TEMP" ]]; then
    trap "rm -rf '$CLEANUP_TEMP'" EXIT
fi

echo "========================================"
echo "  Octo Import"
echo "========================================"
echo ""
echo "  Export package: $EXPORT_DIR"
echo "  Target project: $TARGET_DIR"
echo ""

# --- Validation ---

check_file() {
    if [[ ! -e "$EXPORT_DIR/$1" ]]; then
        echo "ERROR: Missing required file: $1"
        echo "This does not appear to be a valid octo export package."
        exit 1
    fi
}

check_file "project/CLAUDE.md"
check_file "claude-code/settings.json"
check_file "claude-code/plugins-manifest.json"

# Optional files — warn if missing
for optional in "SETUP.md" "CONNECTIONS.md"; do
    if [[ ! -e "$EXPORT_DIR/$optional" ]]; then
        echo "  [WARN] $optional not found in export — check with your admin"
    fi
done

echo "[OK] Export package validated"

# --- Create target if needed ---

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Creating target directory: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

# --- Step 1: Copy project files ---

echo ""
echo "--- Copying project files ---"

cp -v "$EXPORT_DIR/project/CLAUDE.md" "$TARGET_DIR/CLAUDE.md"

if [[ -f "$EXPORT_DIR/project/.mcp.json" ]]; then
    cp -v "$EXPORT_DIR/project/.mcp.json" "$TARGET_DIR/.mcp.json"
fi

if [[ -f "$EXPORT_DIR/project/.gitignore" ]]; then
    cp -v "$EXPORT_DIR/project/.gitignore" "$TARGET_DIR/.gitignore"
fi

if [[ -d "$EXPORT_DIR/project/.planning" ]]; then
    echo "Copying .planning/ directory..."
    cp -r "$EXPORT_DIR/project/.planning" "$TARGET_DIR/.planning"
    PLANNING_COUNT=$(find "$TARGET_DIR/.planning" -type f | wc -l)
    echo "  Copied $PLANNING_COUNT planning files"
fi

# --- Step 2: Set up memory ---

echo ""
echo "--- Setting up Claude Code memory ---"

# Derive the Claude project directory name from the target path
# Claude Code uses the absolute path with / replaced by - and a leading -
CLAUDE_PROJECT_NAME=$(echo "$TARGET_DIR" | sed 's|/|-|g')
CLAUDE_PROJECT_DIR="$CLAUDE_DIR/projects/$CLAUDE_PROJECT_NAME"
MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"

echo "  Claude project dir: $CLAUDE_PROJECT_DIR"
echo "  Memory dir: $MEMORY_DIR"

mkdir -p "$MEMORY_DIR"

if [[ -d "$EXPORT_DIR/claude-code/memory" ]]; then
    MEMORY_COUNT=$(find "$EXPORT_DIR/claude-code/memory" -name "*.md" | wc -l)
    cp -v "$EXPORT_DIR/claude-code/memory/"*.md "$MEMORY_DIR/" 2>/dev/null || true
    echo "  Copied $MEMORY_COUNT memory files"
else
    echo "  No memory files in export"
fi

# --- Step 3: Install hooks ---

echo ""
echo "--- Installing hooks ---"

HOOKS_DIR="$CLAUDE_DIR/hooks"
mkdir -p "$HOOKS_DIR"

if [[ -d "$EXPORT_DIR/claude-code/hooks" ]]; then
    for hook in "$EXPORT_DIR/claude-code/hooks/"*; do
        if [[ -f "$hook" ]]; then
            HOOK_NAME=$(basename "$hook")
            # Replace source user home paths with current user
            sed "s|\$HOME|$HOME|g" "$hook" > "$HOOKS_DIR/$HOOK_NAME"
            chmod +x "$HOOKS_DIR/$HOOK_NAME"
            echo "  Installed hook: $HOOK_NAME"
        fi
    done
else
    echo "  No hooks in export"
fi

# --- Step 4: Merge settings ---

echo ""
echo "--- Merging Claude Code settings ---"

SETTINGS_FILE="$CLAUDE_DIR/settings.json"
EXPORT_SETTINGS="$EXPORT_DIR/claude-code/settings.json"

if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "  No existing settings — copying export settings directly"
    mkdir -p "$CLAUDE_DIR"
    cp "$EXPORT_SETTINGS" "$SETTINGS_FILE"
else
    echo "  Existing settings found — manual merge recommended"
    echo ""
    echo "  Your current settings: $SETTINGS_FILE"
    echo "  Export settings:       $EXPORT_SETTINGS"
    echo ""
    echo "  Use 'jq' or a text editor to merge. Key sections:"
    echo "    - env: environment variables"
    echo "    - hooks: hook configurations"
    echo "    - enabledPlugins: plugin toggle states"
    echo "    - extraKnownMarketplaces: custom plugin sources"
    echo ""
    echo "  Saved export settings to: $CLAUDE_DIR/settings.octo-import.json"
    cp "$EXPORT_SETTINGS" "$CLAUDE_DIR/settings.octo-import.json"
fi

# --- Step 5: Plugin installation commands ---

echo ""
echo "--- Plugin Installation ---"
echo ""
echo "Run these commands to install the required plugins:"
echo ""

if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    with open('$EXPORT_DIR/claude-code/plugins-manifest.json') as f:
        manifest = json.load(f)
    for p in manifest.get('plugins', []):
        status = '[INSTALL]' if p.get('enabled', True) else '[SKIP - disabled]'
        cmd = p.get('install_command', f\"claude plugin add {p['name']}\")
        print(f\"  {status} {cmd}\")
except Exception as e:
    print(f'  Could not parse plugin manifest: {e}', file=sys.stderr)
"
else
    echo "  (python3 not found — read claude-code/plugins-manifest.json manually)"
fi

# --- Step 6: Show connections ---

echo ""
echo "========================================"
echo "  MANUAL STEPS REQUIRED"
echo "========================================"
echo ""
echo "Read the following files for remaining setup:"
echo ""
echo "  1. CONNECTIONS.md — external APIs, data sources, credentials to configure"
echo "     $EXPORT_DIR/CONNECTIONS.md"
echo ""
echo "  2. SETUP.md — full setup guide"
echo "     $EXPORT_DIR/SETUP.md"
echo ""
echo "  3. Settings merge (if needed)"
echo "     $CLAUDE_DIR/settings.octo-import.json"
echo ""

# --- Summary ---

echo "========================================"
echo "  Import Summary"
echo "========================================"

PROJECT_FILES=$(find "$TARGET_DIR" -maxdepth 1 -type f | wc -l)
PLANNING_FILES=$(find "$TARGET_DIR/.planning" -type f 2>/dev/null | wc -l || echo 0)
MEMORY_FILES=$(find "$MEMORY_DIR" -name "*.md" 2>/dev/null | wc -l || echo 0)

echo "  Project files:  $PROJECT_FILES"
echo "  Planning files: $PLANNING_FILES"
echo "  Memory files:   $MEMORY_FILES"
echo ""
echo "  Start a new Claude Code session in $TARGET_DIR to begin."
echo "========================================"
