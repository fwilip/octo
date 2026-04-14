#!/usr/bin/env bash
#
# Octo Export — package a Claude Code project environment for client handoff
#
# Usage:
#   ./export.sh [output-name]
#
# Produces <output-name>.zip (default: octo-export-YYYY-MM-DD.zip)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(pwd)"
EXPORT_NAME="${1:-octo-export-$(date +%Y-%m-%d)}"
EXPORT_NAME="${EXPORT_NAME%.zip}"  # strip .zip if user added it
EXPORT_DIR="./${EXPORT_NAME}"
ZIP_FILE="./${EXPORT_NAME}.zip"
CLAUDE_DIR="$HOME/.claude"

echo "========================================"
echo "  Octo Export"
echo "========================================"
echo ""
echo "  Project: $PROJECT_DIR"
echo "  Output:  $ZIP_FILE"
echo ""

# --- Derive Claude project directory ---

CLAUDE_PROJECT_NAME=$(echo "$PROJECT_DIR" | sed 's|/|-|g')
CLAUDE_PROJECT_DIR="$CLAUDE_DIR/projects/$CLAUDE_PROJECT_NAME"
MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"

echo "  Claude project dir: $CLAUDE_PROJECT_DIR"
echo ""

# --- Create export structure ---

mkdir -p "$EXPORT_DIR/project"
mkdir -p "$EXPORT_DIR/claude-code/memory"
mkdir -p "$EXPORT_DIR/claude-code/hooks"

# --- Step 1: Copy project config files ---

echo "--- Copying project files ---"

if [[ -f "$PROJECT_DIR/CLAUDE.md" ]]; then
    cp "$PROJECT_DIR/CLAUDE.md" "$EXPORT_DIR/project/CLAUDE.md"
    echo "  [OK] CLAUDE.md"
fi

if [[ -f "$PROJECT_DIR/.mcp.json" ]]; then
    cp "$PROJECT_DIR/.mcp.json" "$EXPORT_DIR/project/.mcp.json"
    echo "  [OK] .mcp.json"
fi

if [[ -f "$PROJECT_DIR/.gitignore" ]]; then
    cp "$PROJECT_DIR/.gitignore" "$EXPORT_DIR/project/.gitignore"
    echo "  [OK] .gitignore"
fi

if [[ -d "$PROJECT_DIR/.planning" ]]; then
    cp -r "$PROJECT_DIR/.planning" "$EXPORT_DIR/project/.planning"
    PLANNING_COUNT=$(find "$EXPORT_DIR/project/.planning" -type f | wc -l)
    echo "  [OK] .planning/ ($PLANNING_COUNT files)"
fi

# --- Step 2: Copy memory files ---

echo ""
echo "--- Copying memory files ---"

if [[ -d "$MEMORY_DIR" ]]; then
    cp "$MEMORY_DIR/"*.md "$EXPORT_DIR/claude-code/memory/" 2>/dev/null || true
    MEMORY_COUNT=$(find "$EXPORT_DIR/claude-code/memory" -name "*.md" | wc -l)
    echo "  [OK] $MEMORY_COUNT memory files"
else
    echo "  [SKIP] No memory directory found at $MEMORY_DIR"
fi

# --- Step 3: Run PII scrubber ---

echo ""
echo "--- Running PII scrubber ---"

if command -v python3 &>/dev/null; then
    # Scrub planning docs
    if [[ -d "$EXPORT_DIR/project/.planning" ]]; then
        python3 "$SCRIPT_DIR/pii_scrubber.py" \
            --input-dir "$EXPORT_DIR/project/.planning" \
            --report "$EXPORT_DIR/pii-report-planning.txt"
    fi

    # Scrub memory files
    if [[ -d "$EXPORT_DIR/claude-code/memory" ]]; then
        python3 "$SCRIPT_DIR/pii_scrubber.py" \
            --input-dir "$EXPORT_DIR/claude-code/memory" \
            --report "$EXPORT_DIR/pii-report-memory.txt"
    fi

    # Scrub project config
    python3 "$SCRIPT_DIR/pii_scrubber.py" \
        --input-dir "$EXPORT_DIR/project" \
        --report "$EXPORT_DIR/pii-report-project.txt"

    # Merge reports
    cat "$EXPORT_DIR"/pii-report-*.txt > "$EXPORT_DIR/pii-report.txt" 2>/dev/null || true
    rm -f "$EXPORT_DIR"/pii-report-planning.txt "$EXPORT_DIR"/pii-report-memory.txt "$EXPORT_DIR"/pii-report-project.txt
    echo "  [OK] PII scrub complete — see pii-report.txt"
else
    echo "  [WARN] python3 not found — PII scrubbing skipped!"
    echo "  Run manually: python3 $SCRIPT_DIR/pii_scrubber.py --input-dir $EXPORT_DIR --report $EXPORT_DIR/pii-report.txt"
fi

# --- Step 4: Sanitize settings ---

echo ""
echo "--- Generating sanitized settings ---"

SETTINGS_FILE="$CLAUDE_DIR/settings.json"

if [[ -f "$SETTINGS_FILE" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json, re, sys

with open('$SETTINGS_FILE') as f:
    settings = json.load(f)

sanitized = {}

# Keep env vars but redact secret values
if 'env' in settings:
    sanitized['env'] = {}
    for k, v in settings['env'].items():
        if any(s in k.upper() for s in ['SECRET', 'KEY', 'TOKEN', 'PASSWORD', 'CREDENTIAL', 'AUTH']):
            sanitized['env'][k] = '<SET_THIS>'
        else:
            sanitized['env'][k] = v

# Keep hooks but relativize paths
if 'hooks' in settings:
    hooks_str = json.dumps(settings['hooks'])
    hooks_str = re.sub(r'/home/[a-z_][a-z0-9_-]*', '~', hooks_str)
    hooks_str = hooks_str.replace('$HOME', '~')  # already relative
    sanitized['hooks'] = json.loads(hooks_str)

# Keep plugin toggles
if 'enabledPlugins' in settings:
    sanitized['enabledPlugins'] = settings['enabledPlugins']

# Keep custom marketplaces
if 'extraKnownMarketplaces' in settings:
    sanitized['extraKnownMarketplaces'] = settings['extraKnownMarketplaces']

# Keep status line but relativize
if 'statusLine' in settings:
    sl = json.dumps(settings['statusLine'])
    sl = re.sub(r'/home/[a-z_][a-z0-9_-]*', '~', sl)
    sanitized['statusLine'] = json.loads(sl)

# Keep voice if set
if 'voiceEnabled' in settings:
    sanitized['voiceEnabled'] = settings['voiceEnabled']

with open('$EXPORT_DIR/claude-code/settings.json', 'w') as f:
    json.dump(sanitized, f, indent=2)
    f.write('\n')

print('  [OK] Settings sanitized')
"
else
    echo "  [SKIP] No settings.json or python3 not available"
fi

# --- Step 5: Copy hooks ---

echo ""
echo "--- Copying hooks ---"

HOOKS_SRC="$CLAUDE_DIR/hooks"
if [[ -d "$HOOKS_SRC" ]]; then
    for hook in "$HOOKS_SRC"/*; do
        if [[ -f "$hook" ]]; then
            HOOK_NAME=$(basename "$hook")
            # Relativize paths in hook scripts
            sed "s|/home/[a-z_][a-z0-9_-]*/|\$HOME/|g" "$hook" > "$EXPORT_DIR/claude-code/hooks/$HOOK_NAME"
            echo "  [OK] $HOOK_NAME"
        fi
    done
else
    echo "  [SKIP] No hooks directory"
fi

# --- Step 6: Generate plugin manifest ---

echo ""
echo "--- Generating plugin manifest ---"

PLUGINS_FILE="$CLAUDE_DIR/plugins/installed_plugins.json"

if [[ -f "$PLUGINS_FILE" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json

with open('$PLUGINS_FILE') as f:
    installed = json.load(f)

with open('$SETTINGS_FILE') as f:
    settings = json.load(f)

enabled = settings.get('enabledPlugins', {})
marketplaces_extra = settings.get('extraKnownMarketplaces', {})

with open('$CLAUDE_DIR/plugins/known_marketplaces.json') as f:
    known = json.load(f)

manifest = {'plugins': [], 'marketplaces': {}}

for plugin_key, entries in installed.get('plugins', {}).items():
    name, marketplace = plugin_key.split('@', 1) if '@' in plugin_key else (plugin_key, 'unknown')
    is_enabled = enabled.get(plugin_key, True)

    source = {}
    if marketplace in known:
        source = known[marketplace].get('source', {})
    elif marketplace in marketplaces_extra:
        source = marketplaces_extra[marketplace].get('source', {})

    entry = entries[0] if entries else {}

    manifest['plugins'].append({
        'name': name,
        'marketplace': marketplace,
        'version': entry.get('version', 'latest'),
        'enabled': is_enabled,
        'source': source,
        'install_command': f'claude plugin add {name} --marketplace {marketplace}'
    })

# Add custom marketplaces needed
for mk, mv in marketplaces_extra.items():
    manifest['marketplaces'][mk] = mv

with open('$EXPORT_DIR/claude-code/plugins-manifest.json', 'w') as f:
    json.dump(manifest, f, indent=2)
    f.write('\n')

print(f\"  [OK] {len(manifest['plugins'])} plugins cataloged\")
"
else
    echo "  [SKIP] Could not generate plugin manifest"
fi

# --- Step 7: Copy import script ---

cp "$SCRIPT_DIR/import.sh" "$EXPORT_DIR/import.sh"
chmod +x "$EXPORT_DIR/import.sh"
echo ""
echo "  [OK] import.sh bundled"

# --- Step 8: Create zip ---

echo ""
echo "--- Creating zip package ---"

# Remove previous zip if exists
rm -f "$ZIP_FILE"

# Create zip from the export directory
(cd "$(dirname "$EXPORT_DIR")" && zip -rq "$(basename "$ZIP_FILE")" "$(basename "$EXPORT_DIR")")

ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)
echo "  [OK] $ZIP_FILE ($ZIP_SIZE)"

# Clean up the unzipped directory
rm -rf "$EXPORT_DIR"

# --- Summary ---

echo ""
echo "========================================"
echo "  Export Summary"
echo "========================================"

echo "  Package:  $ZIP_FILE"
echo "  Size:     $ZIP_SIZE"
echo ""
echo "  NEXT STEPS:"
echo "    1. Unzip and review pii-report.txt for false positives/negatives"
echo "    2. Run /octo:export again to auto-generate CONNECTIONS.md and SETUP.md"
echo "       (or write them manually inside the zip)"
echo "    3. Send $ZIP_FILE to the client"
echo "    4. Client installs octo plugin: claude plugin add octo --local /path/to/octo"
echo "    5. Client runs: /octo:import $ZIP_FILE"
echo "========================================"
