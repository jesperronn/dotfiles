# Plan: JaCoCo Coverage CLI Tool (`coverup`)

## Metadata
- start_time: 2026-06-20T09:05:41Z
- input_question: "the python program you just wrote. Generalize it. put it in bin/ folder and use it to show code coverage for all files. git style after -- then take any path and show coverage only for that path. naming: suggest good names. maybe something with coverage/cover/coverup. the tool should be general and look for jacoco-style xml anywhere in the tree. Show both num lines and num branches. another parameter --sort we must be able to sort by percentage, or num lines or num branches or a combo (default) aggregate num lines+num branches. you must write a test that shows the program works. write the program in bash or nodejs. bash has xmllint to fetch from an xml tree"
- creation_time_seconds: ~12
- tool_name: copilot

---

## Context: Original Python Program

The inline Python script written earlier in this session iterates over JaCoCo XML files in a fixed location and prints instruction coverage % and missed branches per file. It served as a prototype for this tool.

```python
import xml.etree.ElementTree as ET, os

files = ['DataadgangeLookup', 'AktoerService', ...]

def check(xml_path, module):
    if not os.path.exists(xml_path): return
    root = ET.parse(xml_path).getroot()
    for pkg in root.findall('.//package'):
        for sf in pkg.findall('sourcefile'):
            name = sf.get('name','').replace('.java','')
            if name in files:
                missed = sum(int(c.get('missed',0)) for c in sf.findall('counter') if c.get('type')=='INSTRUCTION')
                covered = sum(int(c.get('covered',0)) for c in sf.findall('counter') if c.get('type')=='INSTRUCTION')
                total = missed + covered
                pct = round(100*covered/total,1) if total>0 else 100
                bm = sum(int(c.get('missed',0)) for c in sf.findall('counter') if c.get('type')=='BRANCH')
                tag = "100% ✅" if (pct == 100 and bm == 0) else f"{pct}% ({bm} branch missed)"
                print(f"{module}/{name}: {tag}")

check('unilogin-broker-providers/target/site/jacoco/jacoco.xml','broker')
check('unilogin-idp-providers/target/site/jacoco/jacoco.xml','idp')
```

**Limitations of the prototype:**
- Hard-coded paths to JaCoCo XML files
- Hard-coded file filter list
- No sorting
- No path filter (git `--` style)
- Not reusable as a CLI tool

---

## Plan

### 1. Name the tool
Use `coverup` — short, memorable, and on-brand with "coverage" + "cleanup".
- Binary path: `bin/coverup`
- Test path: `bin/coverup.test.sh`

### 2. Choose implementation language
**Node.js** (preferred over bash):
- `xmllint` (bash) is verbose for structured XML traversal and not available everywhere
- Node.js has built-in `child_process` to shell out if needed but also good XML parsing
- Use the lightweight built-in `node:fs` + a pure-JS XML parser (`fast-xml-parser`, already likely available, or use `xmllint` as a subprocess fallback)

Alternatively, use **bash + `xmllint`** if Node.js is unavailable. Prefer Node.js.

> Decision: **Node.js** — write as a single self-contained `.mjs` file, no `package.json` needed if using only built-ins + one optional dependency.

### 3. Tool behaviour spec

```
Usage: coverup [options] [-- <path-filter>]

Options:
  --sort percentage     Sort by coverage % ascending (worst first)
  --sort lines          Sort by missed instruction count descending
  --sort branches       Sort by missed branch count descending
  --sort total          Sort by (missed lines + missed branches) descending [default]
  --root <dir>          Root directory to search for jacoco.xml (default: cwd)
  --help                Show help

Arguments:
  -- <path-filter>      Only show files whose source path contains <path-filter>
                        (matches package path + filename, e.g. "broker" or "AktoerService")
```

**Output columns (tab-aligned):**

```
FILE                                  COV%    LINES  BRANCHES
broker/.../AktoerService.java         100.0%      0         0  ✅
idp/.../LevelOfAssurance.java          99.4%      1         2
idp/.../ChangePasswordOptionsFlow.java 99.9%      0         2
```

- `COV%` = instruction coverage percentage
- `LINES` = missed instruction count
- `BRANCHES` = missed branch count
- ✅ shown when both LINES == 0 and BRANCHES == 0

### 4. XML discovery
Walk the directory tree from `--root` (default `cwd`) and collect all files named `jacoco.xml` (JaCoCo standard output name). Skip `node_modules/`, `.git/`, and any path containing `/test/`.

For each `jacoco.xml` found:
- Parse `<sourcefile>` elements under `<package>` elements
- Extract `<counter type="INSTRUCTION">` and `<counter type="BRANCH">` elements
- Compute `missed_lines`, `covered_lines`, `missed_branches`
- Derive `pct = 100 * covered / (covered + missed)` (or 100 if total == 0)
- Build qualified name: `<package-path>/<filename>` (e.g. `dk/stil/unilogin/broker/.../AktoerService.java`)

### 5. Path filter (`-- <filter>`)
If a path filter argument follows `--`, include only rows where the qualified source file path contains the filter string (case-insensitive substring match).

Examples:
```bash
coverup -- broker
coverup -- AktoerService
coverup -- dk/stil/unilogin/idp/provider/authenticator/password
```

### 6. Sorting

| `--sort` value | Sort key | Direction |
|---|---|---|
| `percentage` | `pct` | ascending (worst first) |
| `lines` | `missed_lines` | descending |
| `branches` | `missed_branches` | descending |
| `total` *(default)* | `missed_lines + missed_branches` | descending |

Ties broken by file path alphabetically.

### 7. Output formatting
- Print a header row
- Align columns with padding (use a fixed-width format or calculate column widths from data)
- Append ✅ when a file is fully covered
- Print a summary footer: total files, total missed lines, total missed branches

### 8. Write tests (`bin/coverup.test.sh`)
Use the bash test pattern from the project's existing `bin/test` runner.

Tests to cover:
1. **No args** — runs against repo root, produces non-empty output
2. **Path filter** — `coverup -- broker` shows only broker files
3. **Path filter exclusion** — `coverup -- idp` shows no broker files
4. **`--sort percentage`** — first row has lowest `COV%`
5. **`--sort lines`** — first data row has highest `LINES` count (or equal top)
6. **`--sort branches`** — first data row has highest `BRANCHES` count (or equal top)
7. **`--sort total`** — default; first row has highest `LINES + BRANCHES`
8. **`--help`** — prints usage, exits 0
9. **Fixture test** — use a synthetic small `jacoco.xml` in `bin/test-fixtures/` to assert exact output lines

### 9. Fixture file
Create `bin/test-fixtures/jacoco-fixtures.xml` — a minimal synthetic JaCoCo XML with 3 source files:
- One fully covered (0 missed, 0 branches)
- One partially covered (some missed instructions, some missed branches)
- One uncovered (all missed)

This allows deterministic assertions in tests without depending on actual build output.

### 10. Implementation steps (execution order)

1. Create `bin/test-fixtures/jacoco.xml` with synthetic data
2. Write `bin/coverup` (Node.js `.mjs` shebang script)
   - XML parsing (use `xmllint --xpath` subprocess or a bundled pure-JS parser)
   - Discovery, filtering, sorting, output
3. `chmod +x bin/coverup`
4. Write `bin/coverup.test.sh`
5. Run tests: `bash bin/coverup.test.sh`
6. Verify against live repo data: `./bin/coverup -- broker`

---

## Notes

- Keep the script a **single file with no external npm dependencies** if possible. Node.js 18+ has `--experimental-vm-modules` and can parse simple XML with regex or the DOM via `jsdom`, but that requires install. Prefer using `xmllint` as a subprocess for XML parsing if `xmllint` is available on macOS (it is, via libxml2); otherwise fall back to a minimal pure-JS XML parser.
- The `--` separator is standard POSIX convention (used by `git`, `grep`, etc.) and should be handled explicitly by the argument parser.
- Avoid colour output by default; add `--color` as a future option.
- The tool must work from any working directory (paths are resolved relative to `--root`).
- Do not suppress 100%-covered files in default mode; use `--only-missing` as a future filter flag.

