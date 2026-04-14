# octo

Export and import project environments with PII isolation.

## What it does

Octo packages a project's configuration, planning docs, memory, settings, hooks, and plugin list into a single `.zip` file with automatic PII scrubbing. The recipient imports the zip to get an identical working environment without any leaked personal data.

## Install

Register the marketplace, then install:

```
/plugin marketplace add fwilip/octo
/plugin install octo@octo
```

## Usage

### Export

```
/octo:export [output-name]
```

Produces `<output-name>.zip` containing project config, planning docs, memory files, sanitized settings, hooks, and a plugin manifest. All files are PII-scrubbed before packaging.

You can also run the shell script directly:

```bash
bash scripts/export.sh [output-name]
```

### Import

```
/octo:import <export.zip>
```

Extracts the zip and restores everything: project files, memory, hooks, settings, and lists the plugins to install.

The zip also contains a standalone `import.sh` that works without the plugin:

```bash
unzip export.zip
cd export-dir
./import.sh /path/to/target/project
```

## PII scrubbing

The bundled scrubber detects and redacts PII across any locale or project type.

### Identifiers

- Email addresses
- US Social Security Numbers
- UK National Insurance Numbers
- EU VAT numbers (all member states)
- Australian Business Numbers
- Canadian Social Insurance Numbers
- Belgian national register numbers
- Dutch BSN numbers
- Passport numbers (labeled)
- Driver's license numbers (labeled)
- Dates of birth (labeled)

### Financial

- IBAN numbers
- Credit card numbers
- SWIFT/BIC codes

### Network and infrastructure

- IPv4 and IPv6 addresses
- AWS account IDs
- API keys and tokens (pattern-matched after key-like labels)

### Physical addresses

- US city/state/zip combinations
- UK postcodes

### System paths

- Unix home directories (`/home/<user>/`)
- macOS home directories (`/Users/<user>/`)
- Windows user directories (`C:\Users\<user>\`)

### Custom blocklists

Add project-specific terms via `--blocklist`:

```bash
python3 scripts/pii_scrubber.py --input-dir ./export --report report.txt --blocklist blocklist.txt
```

Blocklist format (one per line):

```
CompanyName
ProjectCodename|[CODENAME_REDACTED]
/regex-pattern/|[CUSTOM_REPLACEMENT]
```

## What gets exported

| Layer | Treatment |
|-------|-----------|
| CLAUDE.md | Direct copy |
| .mcp.json | Copy, credentials stripped |
| .planning/ | Full tree, PII scrubbed |
| Memory files | Copy, PII scrubbed |
| Settings | Sanitized (secrets replaced, paths relativized) |
| Hooks | Copy, paths relativized |
| Plugin list | Manifest with install commands |

## What gets excluded

- Conversation logs and session history
- Other project data
- Credential values
- Data files (parquet, CSV, Excel)
- Git history

## License

MIT
