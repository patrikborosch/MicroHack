# Local checks and live-evidence boundary

Run from the repository root with Python 3.11+, Node.js and PowerShell 7. No Azure/Fabric
sign-in is needed. Use OS temp for generated examples/evidence, not a tracked folder.

```powershell
$hack = '03-Azure\01-02 Data\04-Agentic_PBIReport_Development'
$env:PYTHONDONTWRITEBYTECODE = '1'
$env:PYTHONIOENCODING = 'utf-8'
python -B -m unittest discover -s "$hack\tests" -p 'test_*.py' -v
python -B "$hack\tests\check-structure.py"
& "$hack\tests\test_automation.ps1"
& "$hack\tests\test_platform_hooks.ps1"
& "$hack\tests\test_fabric_setup.ps1"
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File "$hack\tests\test_fabric_setup.ps1"
az bicep build --file "$hack\labautomation\main.bicep" --outfile "$env:TEMP\agentic-pbi-main.json"
az bicep build --file "$hack\labautomation\shared.bicep" --outfile "$env:TEMP\agentic-pbi-shared.json"
git diff --check
```

The structure adapter calls the existing repository
`.github\scripts\check_file_structure.py` `ComplianceChecker` class over all new
source paths without its cwd-writing command-line wrapper. Use the pinned dependencies in
`.github\scripts\requirements-compliance.txt` in a temporary venv for `brokelink`;
set `PYTHONIOENCODING=utf-8` on Windows. Run `brokelink <file> --include="*.md"
--check-images` on each changed Markdown file. Do not repair unrelated existing
repository links. For deeply nested Windows worktrees, pass an absolute
`\\?\C:\...` filename to the checker to avoid false missing-file results at the
normal Windows path-length limit.

`test_platform_hooks.ps1` runs both actual hook scripts with Azure/platform
boundary doubles and `MHH_EVENT_CONFIG` absent. It exercises shared provisioning,
ordered region selection, retained exact image versions, two participant VMs,
stable retries, secure password parameters, complete guest payload construction,
RG metadata-region differences, preserved platform tags and explicit rejection
of bad scope/identity/context and unsuccessful deployment states. It also checks
empty region preferences, paginated/display-name SKU metadata, capacity Active
waiting, paused-capacity rejection and preservation of unrelated capacities.
Shared deployment uses the platform's Switzerland North default; the participant
hook exercises its matching empty-preference fallback, and explicit overrides
remain supported. Fabric starts unregistered in the fixture: registration must
complete before metadata/deployment. Already-registering, timeout and
permission-denied cases are also covered. ARM doubles return real .NET
`HttpResponseHeaders`, not just hashtables. No Azure call, authentication,
installation or machine configuration occurs.
Thrown and returned deployment failures exercise exception diagnostics,
read-only correlation/operation collection and unavailable diagnostic reads.
Captured logs must retain the synthetic failure codes while excluding the
fixture VM password, complete bootstrap payload and operation request/response.
Secure parameter checks run in C# against the actual hashtable values, as Az's
converter does. A wrapped fixture demonstrates why PowerShell's `-is` check
alone misses this serialization failure; both Bicep secure-string parameters
must reach the cmdlet as native CLR `SecureString` values. Fixtures decode the
bootstrap only privately to inspect its contents and redaction behavior.

`test_automation.ps1` checks runtime policy/reference pins, schemas and signatures,
ownership/implicit disks, ARM polling/failure paths and real temporary ZIP
extraction. Polling tests exercise real `HttpResponseHeaders` for empty headers,
`Azure-AsyncOperation`, `Location` and `Retry-After`, including transient failures
and ambiguous-header rejection, while retaining dictionary compatibility.
Its selective-downloader double stages the actual 25 allowlisted
source files from the pinned Git blobs in OS temp and verifies CSV bytes/checksums
and dictionary links. It checks canonical guest JSON and repeat skill-tree copying.
Diagnostic fixtures also verify inner exception/error-detail visibility and
SecureString, payload, credential-field, URL-query and bearer/JWT redaction.
It does not install Windows tools, run the guest bootstrap, perform interactive
first-login initialization, test MCP connectivity or certify a live tenant.

`test_fabric_setup.ps1` exercises provisioning snapshot reuse/drift/corruption,
idempotent backed-up MCP JSON merges, conflicting server preservation, per-profile
plugin/VSIX setup, disabled updates, interrupted setup retry and isolation of
unrelated user configuration. Provider/host command doubles avoid changing the
author's installed tools, settings or credentials. Configuration completion must
explicitly leave Fabric authentication unverified. Run this suite with the
guest's Windows PowerShell 5.1 as well as PowerShell 7: it covers empty JSON-array
behavior and benign native stderr versus nonzero process exit codes. The actual
bootstrap report-lock validator runs against Node.js with an npm-style empty
root-package key, version mismatches, missing/invalid dependency integrity,
non-HTTPS dependencies, a missing report package and malformed JSON. The live
smoke also invokes this validator on the newly generated npm lock.
Legacy feed checksum fixtures run the actual Node.js conversion with offline
download doubles: verified SHA1 bytes become SHA512, original checksums remain
recorded, frozen retries do not download/rewrite, and checksum mismatches,
missing/unsupported checksums, HTTP URLs and HTTPS-to-HTTP redirects preserve
the unchanged original lock on failure. Live report-runtime smoke runs the same
conversion before validation and `npm ci`.

Optionally run `& "$hack\tests\test_fabric_setup.ps1" -Live` for official public
release metadata, the real complete Fabric archive and actual local marketplace
installation/skill discovery and auxiliary MCP exclusion in a disposable
`COPILOT_HOME` under OS temp. It also resolves/installs the current report runtime
with a new lock, disabled lifecycle scripts and an isolated npm configuration/cache.
It requires the author's Copilot CLI and Node/npm executables but no sign-in. It never deploys,
changes the author's profile, installs Windows tools or authenticates Fabric.
This smoke check is not a replacement for the real VM/dual-host MCP pilot.

`test_packaging.py` applies this lab's documented audience removals and separate
ZIP exclusions to the current source, checks local Markdown file targets with
case-sensitive paths on both published sides, and writes/reads representative
Student/Coach ZIPs in unique OS temp directories. It verifies all 16 CSVs,
manifest/dictionary/brief bytes, required coach source/report parts, absence of
coach content in Student output, and absence of author tests/automation in both.
It also checks retained downloadable Markdown links; lesson pages intentionally
stay on the published sides, not in the ZIPs. Its fixtures catch links to removed
automation/solutions and wrong-case targets. Scratch ZIPs are removed automatically.
These tests model the template contract, not the actual platform importer,
variants, injected banners, link fragments, external websites, private host
VM bootstrap execution. Inspect actual import/navigation/downloads
in the authorized pilot before claiming platform acceptance.

Generate both coach PBIR examples into fresh temporary output folders with
`walkthrough\challenge-03\build-report.py`; run
`powerbi-report-author validate <scenario.Report>` after each source batch.
The locally exercised authoring CLI is 0.1.1; Desktop bridge CLI is 0.1.2.
This is **not** an event-tested toolchain. Schema validation can retrieve public
schemas; cache/pin their hashes and the tested tools for a reproducible event image.

Dataset tests independently recompute controls and test corrupted input; solution
tests check enrichment preserves source bindings, rejects wrong sources and
generates populated, non-overlapping, model-bound reports. These do not execute
DAX, parse a model with TOM, execute Spark, or render Power BI. A fixture seed is
not a service-exported seed.

Live AC-03 through AC-12 still require explicit authorization, disposable pilot
identities and an independent reviewer. See [release gates](../resources/release-gates.md).
