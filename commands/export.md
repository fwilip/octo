---
description: Export this Claude Code project environment as a portable, PII-scrubbed .zip package for client handoff
argument-hint: "[output-name]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, AskUserQuestion
---

# Octo Export

Export the current Claude Code project environment into a self-contained `.zip` package that another person can import to get the exact same Claude Code setup — same memory, same behavioral rules, same plugins, same MCP config — without any PII leakage from other clients or projects.

The output is a single `.zip` file the client can import with `/octo:import <file.zip>`.

## What Gets Exported

| Layer | Source | Treatment |
|-------|--------|-----------|
| CLAUDE.md | Project root | Direct copy |
| .mcp.json | Project root | Copy, strip credential values |
| .planning/ | Project root | Copy all, PII scrub |
| Auto-memory | `~/.claude/projects/<project>/memory/` | Copy all .md files, PII scrub |
| Global settings | `~/.claude/settings.json` | Sanitized extract (plugins, hooks, env var names) |
| Hooks | `~/.claude/hooks/` | Copy scripts |
| Plugin manifest | `~/.claude/plugins/installed_plugins.json` | Extract install commands |

## What Gets Excluded

- Conversation logs (`*.jsonl` — session history, 600MB+)
- Session artifacts (UUID directories)
- Other project memories (`~/.claude/projects/` for other repos)
- Data files (parquet, CSV, Excel — handle separately)
- Credential values (API keys, tokens, passwords)
- Git history (client gets fresh repo state)

## Execution Steps

Follow these steps exactly. Run independent steps in parallel where noted.

### Step 1: Determine output name

If `$ARGUMENTS` is provided, use it as the base name. Otherwise use `octo-export-YYYY-MM-DD`. The final output is `<name>.zip`.

```bash
EXPORT_NAME="${ARGUMENTS:-octo-export-$(date +%Y-%m-%d)}"
```

### Step 2: Discover project paths (parallel)

Gather all paths needed:

1. **Project root**: Current working directory
2. **Claude project dir**: Derive from `~/.claude/projects/` — the directory name is the CWD path with `/` replaced by `-` and leading `-`
3. **Memory dir**: `<claude-project-dir>/memory/`
4. **Global settings**: `~/.claude/settings.json`
5. **Hooks dir**: `~/.claude/hooks/`
6. **Installed plugins**: `~/.claude/plugins/installed_plugins.json`
7. **Known marketplaces**: `~/.claude/plugins/known_marketplaces.json`

### Step 3: Create export structure

The zip contains a single top-level directory with this layout:

```
<export-name>/
├── project/
│   ├── CLAUDE.md
│   ├── .mcp.json
│   └── .planning/          (full tree)
├── claude-code/
│   ├── memory/              (scrubbed .md files)
│   ├── settings.json        (sanitized)
│   ├── hooks/               (hook scripts)
│   └── plugins-manifest.json (what to install)
├── pii-report.txt           (what was scrubbed and why)
├── CONNECTIONS.md            (external deps the client must set up)
├── SETUP.md                  (step-by-step import guide)
└── import.sh                 (automated import script — works without octo plugin)
```

### Step 4: Copy project config files

Copy these from the project root into `<export-dir>/project/`:
- `CLAUDE.md`
- `.mcp.json` (if exists)
- `.gitignore` (if exists)
- `.planning/` (full directory tree — recursive copy)

### Step 5: Run PII scrubber on planning docs

Use the bundled PII scrubber script to process all files in `<export-dir>/project/.planning/`:

```bash
python3 "$(dirname "$0")/../scripts/pii_scrubber.py" \
  --input-dir "<export-dir>/project/.planning" \
  --report "<export-dir>/pii-report.txt" \
  --mode scrub
```

The scrubber targets:
- **Email addresses** → `[EMAIL_REDACTED]`
- **Phone numbers** (Belgian/international) → `[PHONE_REDACTED]`
- **Belgian VAT numbers** (BE + 10 digits) → `[VAT_REDACTED]`
- **IP addresses** (v4 and v6) → `[IP_REDACTED]`
- **Home directory paths** (`/home/<user>/`) → `~/`
- **Absolute machine paths** → relativized
- **Known PII patterns** from a configurable blocklist

After scrubbing, review the `pii-report.txt` to verify nothing was missed or over-scrubbed.

### Step 6: Copy and scrub memory files

1. Copy all `.md` files from the Claude project memory directory into `<export-dir>/claude-code/memory/`
2. Run the PII scrubber on the memory directory too
3. Verify the MEMORY.md index still makes sense after scrubbing

### Step 7: Generate sanitized settings

Read `~/.claude/settings.json` and produce a sanitized version at `<export-dir>/claude-code/settings.json`:

- **Keep**: `env` block (but replace values of keys containing SECRET/KEY/TOKEN/PASSWORD with `"<SET_THIS>"`)
- **Keep**: `hooks` block (but relativize any absolute paths)
- **Keep**: `enabledPlugins` block as-is
- **Keep**: `extraKnownMarketplaces` block as-is
- **Keep**: `statusLine` block (relativize paths)
- **Remove**: `skipDangerousModePermissionPrompt` and similar personal prefs
- **Remove**: any keys not in the above list

### Step 8: Copy hooks

Copy all files from `~/.claude/hooks/` into `<export-dir>/claude-code/hooks/`. Relativize any hardcoded paths inside the scripts.

### Step 9: Generate plugin manifest

Read `~/.claude/plugins/installed_plugins.json` and `~/.claude/settings.json` (enabledPlugins), then generate `<export-dir>/claude-code/plugins-manifest.json`:

```json
{
  "plugins": [
    {
      "name": "superpowers",
      "marketplace": "claude-plugins-official",
      "source": {"source": "github", "repo": "anthropics/claude-plugins-official"},
      "enabled": true,
      "install_command": "claude plugin add superpowers --marketplace claude-plugins-official"
    }
  ],
  "marketplaces": {
    "openai-codex": {
      "source": {"source": "github", "repo": "openai/codex-plugin-cc"},
      "settings_key": "extraKnownMarketplaces"
    }
  }
}
```

### Step 10: Generate CONNECTIONS.md

Scan the exported project files and memory to identify external dependencies. Create `<export-dir>/CONNECTIONS.md` with:

```markdown
# External Connections Required

This project depends on external services, APIs, and data sources that
Claude Code cannot automatically set up. You must configure these manually.

## API Keys / Credentials

| Service | Env Var | Purpose | Where to Get |
|---------|---------|---------|--------------|
| ... | ... | ... | ... |

## MCP Servers

| Server | Command | Purpose |
|--------|---------|---------|
| ... | ... | ... |

## Data Sources

| Name | Format | Description | How to Obtain |
|------|--------|-------------|---------------|
| ... | ... | ... | ... |

## External Services

| Service | URL/Endpoint | Purpose |
|---------|-------------|---------|
| ... | ... | ... |

## Infrastructure

| Component | Requirement | Notes |
|-----------|-------------|-------|
| Python venv | 3.10+ | Pipeline scripts |
| ... | ... | ... |
```

To populate this, scan for:
- `os.environ`, `os.getenv` in Python files
- API base URLs in code
- Import statements for external services
- MCP server configs in `.mcp.json`
- References to external data files in `.planning/`
- Database connection strings
- Proxy configurations

### Step 11: Generate SETUP.md

Create a step-by-step guide at `<export-dir>/SETUP.md`:

```markdown
# Setup Guide

## Prerequisites

- Claude Code CLI installed (`npm install -g @anthropic-ai/claude-code`)
- Node.js 18+
- Python 3.10+ (for pipeline scripts)

## Quick Setup

Run the automated import:
```bash
chmod +x import.sh && ./import.sh /path/to/your/project
```

## Manual Setup

### 1. Project Files
Copy `project/` contents to your project root.

### 2. Memory
The import script places memory files in the correct Claude Code
project directory. If manual: copy `claude-code/memory/` to
`~/.claude/projects/<your-project-path>/memory/`

### 3. Plugins
Install each plugin listed in `claude-code/plugins-manifest.json`:
[generated install commands]

### 4. Settings
Merge `claude-code/settings.json` into `~/.claude/settings.json`.

### 5. Hooks
Copy `claude-code/hooks/` to `~/.claude/hooks/`.

### 6. External Connections
See CONNECTIONS.md for all external dependencies to configure.
```

### Step 12: Generate import.sh

Create `<export-dir>/import.sh` — a self-contained bash script that automates the import. See the import command for details, but the script should be standalone (no dependency on the octo plugin being installed on the target machine).

### Step 13: Create zip

Package the export directory into a single `.zip` file:

```bash
cd "$(dirname "$EXPORT_DIR")" && zip -rq "<export-name>.zip" "<export-name>/"
```

Remove the unzipped directory after creating the zip.

### Step 14: Ask user to review

After export completes, tell the user:
1. Zip file path and size
2. Number of PII items scrubbed (from pii-report.txt inside the zip)
3. Remind them to unzip and review `pii-report.txt` for false positives/negatives
4. Remind them to review `CONNECTIONS.md` for completeness
5. Tell them the client can import with either:
   - `/octo:import <file.zip>` (if octo plugin is installed)
   - `unzip <file.zip> && cd <dir> && ./import.sh /path/to/project` (standalone)

## Important Notes

- NEVER include conversation logs (*.jsonl) — they contain full chat history
- NEVER include UUID session directories — they are ephemeral artifacts
- ALWAYS relativize absolute paths (`/home/filip/` → `~/`)
- ALWAYS strip credential values but keep the key names
- The PII scrubber is conservative — it's better to over-scrub than leak
- The client can always add back domain-specific terms that were false-positived
