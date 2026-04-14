#!/usr/bin/env python3
"""
Octo PII Scrubber — scans and redacts personally identifiable information
from text files while preserving structural/technical content.

Usage:
    python3 pii_scrubber.py --input-dir ./export --report ./pii-report.txt
    python3 pii_scrubber.py --input-file ./notes.md --report ./pii-report.txt
    python3 pii_scrubber.py --input-dir ./export --report ./report.txt --dry-run
    python3 pii_scrubber.py --input-dir ./export --report ./report.txt --blocklist ./blocklist.txt
"""

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class ScrubMatch:
    file: str
    line_num: int
    pattern_name: str
    original: str
    replacement: str
    context: str


@dataclass
class ScrubReport:
    matches: list = field(default_factory=list)
    files_scanned: int = 0
    files_modified: int = 0
    skipped_binary: int = 0

    def add(self, match: ScrubMatch):
        self.matches.append(match)

    def summary(self) -> str:
        lines = [
            "=" * 60,
            "OCTO PII SCRUB REPORT",
            "=" * 60,
            f"Files scanned:  {self.files_scanned}",
            f"Files modified: {self.files_modified}",
            f"Binary skipped: {self.skipped_binary}",
            f"Total redactions: {len(self.matches)}",
            "",
        ]

        by_pattern = {}
        for m in self.matches:
            by_pattern.setdefault(m.pattern_name, []).append(m)

        for pattern, items in sorted(by_pattern.items()):
            lines.append(f"--- {pattern} ({len(items)} matches) ---")
            for item in items:
                lines.append(f"  {item.file}:{item.line_num}")
                lines.append(f"    BEFORE: {item.original}")
                lines.append(f"    AFTER:  {item.replacement}")
                if item.context:
                    lines.append(f"    CONTEXT: ...{item.context}...")
            lines.append("")

        lines.append("=" * 60)
        lines.append("Review this report for false positives (over-scrubbed)")
        lines.append("and false negatives (PII that was missed).")
        lines.append("=" * 60)
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# PII Pattern Definitions
#
# Organized by category. Each tuple is (name, compiled_regex, replacement).
# Patterns are applied in order — put high-confidence patterns first.
# ---------------------------------------------------------------------------

PATTERNS = [
    # ── Emails ────────────────────────────────────────────────────────────
    (
        "email",
        re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b"),
        "[EMAIL_REDACTED]",
    ),

    # ── Phone numbers ─────────────────────────────────────────────────────
    # International format: +1 555-123-4567, +44 (20) 7946 0958, etc.
    (
        "phone_intl",
        re.compile(
            r"\+\d{1,3}[\s.-]?\(?\d{1,4}\)?[\s.-]?\d{2,4}[\s.-]?\d{2,4}[\s.-]?\d{0,4}"
        ),
        "[PHONE_REDACTED]",
    ),
    # North American: (555) 123-4567, 555-123-4567, 555.123.4567
    (
        "phone_na",
        re.compile(
            r"\(?\d{3}\)?[\s.\-]\d{3}[\s.\-]\d{4}\b"
        ),
        "[PHONE_REDACTED]",
    ),
    # European landline/mobile with separators: 020 123 45 67, 06-12345678
    (
        "phone_eu",
        re.compile(r"\b0\d{1,3}[\s.\-]\d{2,4}[\s.\-]\d{2,4}(?:[\s.\-]\d{2,4})?\b"),
        "[PHONE_REDACTED]",
    ),

    # ── National ID / Tax numbers ─────────────────────────────────────────
    # US Social Security Number: 123-45-6789
    (
        "ssn",
        re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
        "[SSN_REDACTED]",
    ),
    # UK National Insurance Number: AB 12 34 56 C
    (
        "uk_nino",
        re.compile(
            r"\b[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z]\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b"
        ),
        "[NINO_REDACTED]",
    ),
    # EU VAT numbers (all member states): country code + 8-12 alphanumeric
    (
        "eu_vat",
        re.compile(
            r"\b(?:AT|BE|BG|CY|CZ|DE|DK|EE|EL|ES|FI|FR|GB|HR|HU|IE|IT|LT|LU|LV|MT|NL|PL|PT|RO|SE|SI|SK)"
            r"[\s.]?\d[\s.]?[A-Z0-9]{6,11}\b"
        ),
        "[VAT_REDACTED]",
    ),
    # Australian Business Number: 11 digit
    (
        "abn",
        re.compile(r"\bABN[\s:]*\d{2}[\s]?\d{3}[\s]?\d{3}[\s]?\d{3}\b"),
        "[ABN_REDACTED]",
    ),
    # Canadian SIN: 123 456 789
    (
        "ca_sin",
        re.compile(r"\b\d{3}\s\d{3}\s\d{3}\b"),
        "[SIN_REDACTED]",
    ),
    # Belgian national register: YY.MM.DD-XXX.XX
    (
        "national_register",
        re.compile(r"\b\d{2}\.\d{2}\.\d{2}-\d{3}\.\d{2}\b"),
        "[NATL_REG_REDACTED]",
    ),
    # BSN (Netherlands): 9 digits often written with dots
    (
        "bsn",
        re.compile(r"\bBSN[\s:]*\d{3}[\s.]?\d{2}[\s.]?\d{3,4}\b", re.IGNORECASE),
        "[BSN_REDACTED]",
    ),

    # ── Financial ─────────────────────────────────────────────────────────
    # IBAN: 2 letters + 2 check digits + up to 30 alphanumeric
    (
        "iban",
        re.compile(r"\b[A-Z]{2}\d{2}[\s]?[A-Z0-9]{4}[\s]?[A-Z0-9]{4}[\s]?[A-Z0-9]{4}[\s]?[A-Z0-9]{0,18}\b"),
        "[IBAN_REDACTED]",
    ),
    # Credit card: 16 digits in groups of 4
    (
        "credit_card",
        re.compile(r"\b(?:\d{4}[\s-]?){3}\d{4}\b"),
        "[CC_REDACTED]",
    ),
    # SWIFT/BIC code: 8 or 11 alphanumeric
    (
        "swift",
        re.compile(r"\b[A-Z]{6}[A-Z0-9]{2}(?:[A-Z0-9]{3})?\b"),
        "[SWIFT_REDACTED]",
    ),

    # ── Network / Infrastructure ──────────────────────────────────────────
    # IPv4
    (
        "ipv4",
        re.compile(
            r"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}"
            r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"
        ),
        "[IP_REDACTED]",
    ),
    # IPv6 full form
    (
        "ipv6",
        re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b"),
        "[IP_REDACTED]",
    ),
    # AWS account IDs: 12 digits often after "account" or "arn:"
    (
        "aws_account",
        re.compile(r"(?:account[\s:]*|arn:aws:[a-z0-9-]+:[\w-]*:)\d{12}\b"),
        "[AWS_ACCT_REDACTED]",
    ),
    # Generic API keys / tokens: long hex or base64 strings after key-like words
    (
        "api_key_value",
        re.compile(
            r'(?:api[_-]?key|api[_-]?secret|token|secret|password|credential|auth[_-]?token)'
            r'[\s]*[=:]\s*["\']?([A-Za-z0-9+/=_\-]{20,})["\']?',
            re.IGNORECASE,
        ),
        "[SECRET_REDACTED]",
    ),

    # ── Physical addresses ────────────────────────────────────────────────
    # US zip codes in context: city, ST 12345 or city, ST 12345-6789
    (
        "us_zip_context",
        re.compile(r"\b[A-Z][a-z]+(?:\s[A-Z][a-z]+)*,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?\b"),
        "[ADDRESS_REDACTED]",
    ),
    # UK postcodes: A9 9AA, A99 9AA, A9A 9AA, AA9 9AA, AA99 9AA, AA9A 9AA
    (
        "uk_postcode",
        re.compile(
            r"\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b"
        ),
        "[POSTCODE_REDACTED]",
    ),

    # ── Personal identifiers ──────────────────────────────────────────────
    # Passport numbers (generic): 1-2 letters + 6-9 digits
    (
        "passport",
        re.compile(r"\b(?:passport|paspoort|reisepass)[\s:#]*[A-Z]{1,2}\d{6,9}\b", re.IGNORECASE),
        "[PASSPORT_REDACTED]",
    ),
    # Driver's license (labeled)
    (
        "drivers_license",
        re.compile(
            r"(?:driver'?s?\s*licen[sc]e|rijbewijs|permis\s*de\s*conduire)[\s:#]*[A-Z0-9]{5,15}\b",
            re.IGNORECASE,
        ),
        "[LICENSE_REDACTED]",
    ),
    # Date of birth (labeled): DOB/born/geboren followed by date
    (
        "dob",
        re.compile(
            r"(?:d\.?o\.?b\.?|date\s*of\s*birth|born|geboren|geboortedatum)"
            r"[\s:]*\d{1,4}[\s./-]\d{1,2}[\s./-]\d{1,4}",
            re.IGNORECASE,
        ),
        "[DOB_REDACTED]",
    ),
]

# Contextual patterns: always applied but categorized separately
CONTEXTUAL_PATTERNS = [
    # Unix home directory paths — leak username
    (
        "home_path",
        re.compile(r"/home/[a-z_][a-z0-9_-]*"),
        "~",
    ),
    # macOS home directory paths
    (
        "mac_home_path",
        re.compile(r"/Users/[A-Za-z0-9._-]+"),
        "~",
    ),
    # Windows user paths
    (
        "windows_user_path",
        re.compile(r"C:\\Users\\[A-Za-z0-9._-]+"),
        "C:\\Users\\<USER>",
    ),
]

# Patterns that look like SWIFT codes but are common English words / acronyms
SWIFT_ALLOWLIST = {
    "EXAMPLES", "OVERVIEW", "COMPLETE", "INTERNAL", "EXTERNAL",
    "OPTIONAL", "REQUIRED", "ABSTRACT", "FUNCTION", "TEMPLATE",
    "MANIFEST", "INSTANCE", "FEATURES", "SETTINGS", "METADATA",
    "PLANNING", "PATTERNS", "PIPELINE", "GENERATE", "ANALYSIS",
    "COMMANDS", "CONTENTS", "BLOCKLIST",
}


def is_binary(filepath: Path) -> bool:
    try:
        with open(filepath, "rb") as f:
            chunk = f.read(8192)
            return b"\x00" in chunk
    except (OSError, PermissionError):
        return True


def load_blocklist(path: Path) -> list[tuple[str, re.Pattern, str]]:
    """Load custom blocklist — one term per line, optionally with replacement.

    Format:
        term                    -> replaced with [REDACTED]
        term|replacement        -> replaced with custom text
        /regex/|replacement     -> regex pattern with replacement
    """
    extra_patterns = []
    if not path.exists():
        return extra_patterns

    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        if "|" in line:
            term, replacement = line.split("|", 1)
            term = term.strip()
            replacement = replacement.strip()
        else:
            term = line
            replacement = "[REDACTED]"

        if term.startswith("/") and term.endswith("/"):
            pattern = re.compile(term[1:-1], re.IGNORECASE)
        else:
            pattern = re.compile(re.escape(term), re.IGNORECASE)

        extra_patterns.append(("blocklist", pattern, replacement))

    return extra_patterns


def get_context(text: str, start: int, end: int, radius: int = 30) -> str:
    ctx_start = max(0, start - radius)
    ctx_end = min(len(text), end + radius)
    return text[ctx_start:ctx_end].replace("\n", " ")


def should_skip_ip(text: str, match: re.Match) -> bool:
    """Skip IP-like patterns that are version numbers or localhost."""
    val = match.group()
    # Skip common non-PII addresses
    if val in ("127.0.0.1", "0.0.0.0", "255.255.255.255", "255.255.255.0"):
        return True
    start = max(0, match.start() - 5)
    prefix = text[start : match.start()]
    if re.search(r"[v=:]$", prefix.rstrip()):
        return True
    parts = val.split(".")
    if len(parts) >= 3 and all(int(p) < 50 for p in parts[:3]):
        return True
    return False


def should_skip_swift(match: re.Match) -> bool:
    """Skip SWIFT-like patterns that are common words."""
    val = match.group()
    return val.upper() in SWIFT_ALLOWLIST or val.upper() == val and len(val) > 8


def scrub_text(
    text: str,
    filepath: str,
    all_patterns: list[tuple[str, re.Pattern, str]],
    report: ScrubReport,
    dry_run: bool = False,
) -> str:
    lines = text.split("\n")
    result_lines = []

    for line_num, line in enumerate(lines, 1):
        modified = line
        for name, pattern, replacement in all_patterns:
            for match in pattern.finditer(modified):
                if name == "ipv4" and should_skip_ip(text, match):
                    continue
                if name == "swift" and should_skip_swift(match):
                    continue
                if name == "iban" and ("http" in modified or "sha" in modified.lower()):
                    continue
                if name == "credit_card":
                    val = match.group().replace(" ", "").replace("-", "")
                    if len(val) != 16 or not val.isdigit():
                        continue
                # Skip Canadian SIN false positives in numeric contexts
                if name == "ca_sin" and re.search(r"(?:version|phase|step|v)\s*$", modified[:match.start()], re.IGNORECASE):
                    continue
                # For api_key_value, replace the full match
                if name == "api_key_value":
                    original = match.group()
                else:
                    original = match.group()

                context = get_context(modified, match.start(), match.end())

                report.add(
                    ScrubMatch(
                        file=filepath,
                        line_num=line_num,
                        pattern_name=name,
                        original=original,
                        replacement=replacement,
                        context=context,
                    )
                )

                if not dry_run:
                    modified = modified[: match.start()] + replacement + modified[match.end() :]
                    break  # re-scan line since offsets changed

        for name, pattern, replacement in CONTEXTUAL_PATTERNS:
            for match in pattern.finditer(modified):
                original = match.group()
                context = get_context(modified, match.start(), match.end())

                report.add(
                    ScrubMatch(
                        file=filepath,
                        line_num=line_num,
                        pattern_name=name,
                        original=original,
                        replacement=replacement,
                        context=context,
                    )
                )

                if not dry_run:
                    modified = modified.replace(original, replacement)

        result_lines.append(modified)

    return "\n".join(result_lines)


def scrub_file(
    filepath: Path,
    all_patterns: list[tuple[str, re.Pattern, str]],
    report: ScrubReport,
    dry_run: bool = False,
) -> bool:
    if is_binary(filepath):
        report.skipped_binary += 1
        return False

    suffix = filepath.suffix.lower()
    if suffix not in {
        ".md", ".txt", ".json", ".yaml", ".yml", ".toml",
        ".py", ".js", ".ts", ".sh", ".bash", ".cfg", ".ini",
        ".env.example", ".csv", ".xml", ".html", ".htm",
        ".jsx", ".tsx", ".rb", ".go", ".rs", ".java", ".kt",
        ".scala", ".r", ".sql", ".tf", ".hcl", ".conf",
        ".properties", ".gradle", ".plist",
    }:
        return False

    report.files_scanned += 1

    try:
        original_text = filepath.read_text(encoding="utf-8", errors="replace")
    except (OSError, PermissionError) as e:
        print(f"  WARN: Cannot read {filepath}: {e}", file=sys.stderr)
        return False

    matches_before = len(report.matches)
    scrubbed = scrub_text(
        original_text, str(filepath), all_patterns, report, dry_run=dry_run,
    )

    if len(report.matches) > matches_before and not dry_run:
        filepath.write_text(scrubbed, encoding="utf-8")
        report.files_modified += 1
        return True

    return False


def scrub_directory(
    dirpath: Path,
    all_patterns: list[tuple[str, re.Pattern, str]],
    report: ScrubReport,
    dry_run: bool = False,
):
    for root, dirs, files in os.walk(dirpath):
        dirs[:] = [d for d in dirs if not d.startswith(".") or d in (".planning", ".claude")]
        for fname in sorted(files):
            fpath = Path(root) / fname
            scrub_file(fpath, all_patterns, report, dry_run=dry_run)


def main():
    parser = argparse.ArgumentParser(
        description="Octo PII Scrubber — redact PII from exported project files"
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--input-dir", type=Path, help="Directory to scrub recursively")
    group.add_argument("--input-file", type=Path, help="Single file to scrub")
    parser.add_argument(
        "--report", type=Path, required=True, help="Output path for scrub report"
    )
    parser.add_argument(
        "--blocklist", type=Path, default=None,
        help="Custom blocklist file (one term per line, # for comments, term|replacement for custom)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Report what would be scrubbed without modifying files"
    )
    parser.add_argument(
        "--mode", choices=["scrub", "report-only"], default="scrub",
        help="scrub = modify files; report-only = just generate report"
    )

    args = parser.parse_args()

    if args.mode == "report-only":
        args.dry_run = True

    all_patterns = list(PATTERNS)
    if args.blocklist:
        extra = load_blocklist(args.blocklist)
        all_patterns.extend(extra)
        print(f"Loaded {len(extra)} blocklist patterns from {args.blocklist}")

    report = ScrubReport()

    if args.input_dir:
        if not args.input_dir.is_dir():
            print(f"ERROR: {args.input_dir} is not a directory", file=sys.stderr)
            sys.exit(1)
        print(f"Scrubbing directory: {args.input_dir}")
        scrub_directory(args.input_dir, all_patterns, report, dry_run=args.dry_run)
    else:
        if not args.input_file.is_file():
            print(f"ERROR: {args.input_file} is not a file", file=sys.stderr)
            sys.exit(1)
        print(f"Scrubbing file: {args.input_file}")
        scrub_file(args.input_file, all_patterns, report, dry_run=args.dry_run)

    report_text = report.summary()
    args.report.write_text(report_text, encoding="utf-8")
    print(f"\nReport written to: {args.report}")
    print(f"  Files scanned:  {report.files_scanned}")
    print(f"  Files modified: {report.files_modified}")
    print(f"  Total redactions: {len(report.matches)}")

    if args.dry_run:
        print("\n  (DRY RUN — no files were modified)")


if __name__ == "__main__":
    main()
