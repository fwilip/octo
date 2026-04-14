---
description: Import an octo export .zip or directory into this Claude Code environment — restores memory, plugins, settings, and config
argument-hint: "<export.zip or export-dir>"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
---

# Octo Import

Import a previously exported Claude Code environment package into the current project. Accepts a `.zip` file or an extracted directory. This sets up memory, plugins, settings, hooks, and project configuration so Claude Code works identically to the source environment.

## Prerequisites

- An octo export `.zip` file or extracted directory (created by `/octo:export`)
- Claude Code CLI installed
- Current working directory is the target project root

## Execution Steps

### Step 1: Extract and validate export package

If `$ARGUMENTS` ends in `.zip`, extract it to a temp directory first:

```bash
TEMP_DIR=$(mktemp -d)
unzip -qo "$ARGUMENTS" -d "$TEMP_DIR"
# If zip contains a single top-level dir, descend into it
EXPORT_DIR="$TEMP_DIR/<single-dir>"
```

Then validate the export directory contains:
- `project/CLAUDE.md` (required)
- `claude-code/settings.json` (required)
- `claude-code/plugins-manifest.json` (required)
- `SETUP.md` (optional — warn if missing)
- `CONNECTIONS.md` (optional — warn if missing)

If required files are missing, tell the user which files are missing and stop.

### Step 2: Ask for confirmation

Show the user what will be imported and modified:
- List files that will be copied to the project root
- List plugins that will be installed
- List settings that will be merged
- Warn about any existing files that will be overwritten

Ask: "Proceed with import? (This will overwrite existing CLAUDE.md, .mcp.json, and .planning/ if present)"

### Step 3: Copy project files

From `<export-dir>/project/` to the current project root:
- `CLAUDE.md` → project root
- `.mcp.json` → project root (if exists in export)
- `.gitignore` → project root (if exists in export)
- `.planning/` → project root (recursive, overwrite)

### Step 4: Set up memory

1. Determine the Claude project directory path:
   - The project dir name is derived from the absolute path of CWD: replace `/` with `-`, prepend `-`
   - Full path: `~/.claude/projects/<derived-name>/memory/`
2. Create the memory directory if it doesn't exist
3. Copy all `.md` files from `<export-dir>/claude-code/memory/` into it
4. Verify `MEMORY.md` exists and is readable

### Step 5: Install plugins

Read `<export-dir>/claude-code/plugins-manifest.json`. For each plugin:

1. Check if the plugin is already installed (check `~/.claude/plugins/installed_plugins.json`)
2. If not installed, show the install command and ask the user to run it:
   ```
   claude plugin add <name> --marketplace <marketplace>
   ```
3. For plugins from custom marketplaces (extraKnownMarketplaces), first add the marketplace to settings

Note: Plugin installation requires interactive Claude CLI commands. List all commands for the user to run, or run them via bash if `claude` CLI is available.

### Step 6: Merge settings

Read `<export-dir>/claude-code/settings.json` and merge into `~/.claude/settings.json`:

- **env**: Add missing env vars. For vars with `"<SET_THIS>"` values, ask the user to provide the actual value
- **hooks**: Merge hook entries (don't duplicate existing ones)
- **enabledPlugins**: Enable plugins listed in the export
- **extraKnownMarketplaces**: Add missing marketplace entries
- **statusLine**: Copy if user doesn't have one configured

NEVER overwrite existing settings values — only add missing ones. Ask user about conflicts.

### Step 7: Install hooks

1. Copy hook scripts from `<export-dir>/claude-code/hooks/` to `~/.claude/hooks/`
2. Make them executable (`chmod +x`)
3. Update any paths inside the scripts to point to the new user's home directory

### Step 8: Show connection checklist

Read `<export-dir>/CONNECTIONS.md` and present it as an actionable checklist:

```
The following external connections need to be configured manually:

[ ] API Key: SERPER_API_KEY — Get from serper.dev
[ ] API Key: DECODO_PROXY — Proxy credentials for web scraping
[ ] Data: dynamo_full_extract.parquet — Request from data team
...
```

### Step 9: Validate setup

Run basic validation:
1. Check CLAUDE.md exists and is readable
2. Check memory files are in the right location
3. Check `.mcp.json` is valid JSON
4. Check `~/.claude/settings.json` is valid JSON after merge
5. List any env vars that still have `"<SET_THIS>"` placeholder values

### Step 10: Summary

Report:
- Number of files copied
- Plugins installed vs already present
- Settings merged
- Outstanding manual steps (from CONNECTIONS.md)
- Any warnings or issues

Tell the user: "Import complete. Start a new Claude Code session in this directory to use the imported environment. Check CONNECTIONS.md for external dependencies you still need to configure."
