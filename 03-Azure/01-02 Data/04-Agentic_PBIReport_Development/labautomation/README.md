# Lab automation - Testing

The two hooks use the documented MicroHack platform contract. **No private file,
custom environment variable, mounted approval document or extra hook parameter is
required.** The previous `MHH_EVENT_CONFIG` dependency was a lab integration bug;
it has been removed from both hooks, not replaced with the incomplete example.

This is deployment source, not a live acceptance result. Local checks do not prove
Azure region/quota availability, successful Windows installation, tenant policy,
licenses or the complete learner journey.

## Runtime inputs and repository settings

The platform supplies authenticated, isolated Az/CLI contexts and helpers:

| Hook | Inputs |
| --- | --- |
| `shared-deploy-lab.ps1` | `SubscriptionId`, `PreferredLocation`, subscription-scoped `AllowedEntraUserIds` |
| `deploy-lab.ps1` | `DeploymentType`, `SubscriptionId`, `ResourceGroupName`, `PreferredLocation`, one participant's `AllowedEntraUserIds` |

The participant hook supports `resourcegroup` only, and uses the existing
platform-created RG. It does not authenticate, switch subscription, create users,
buy/assign licenses or grant participants capacity administration. The platform
grants subscription Reader and participant-RG Owner; this exposes shared Azure
metadata but is not access to other participants' VM credentials or Fabric data.

[lab-settings.psd1](lab-settings.psd1) holds **nonsecret implementation defaults**:
Windows Server 2022 Datacenter Gen2 (Azure license included, no Hybrid Benefit),
`Standard_D4s_v5`, 128 GB OS disk, shared Standard Bastion with two scale units,
immutable student source and the latest-stable-at-provisioning package policy.
These are source defaults, not measured cohort, budget or performance approvals.
Review changes to this file normally; never add credentials or private identities.

The platform default in `lab-defaults.json` is **Switzerland North**
(`switzerlandnorth`), matching the hook's fallback when no preference is supplied.
Explicit platform region overrides remain supported. The shared hook tries the
supplied region order against F16 and Bastion provider metadata, then resolves
an available exact Windows image version. The chosen region and image
version are retained on the owned shared resources and reused on retries; `latest`
is not passed to ARM. VM SKU availability, quota, Azure Policy and paid-service
capacity can still reject deployment. Both hooks check `Microsoft.Fabric`,
`Microsoft.Compute` and `Microsoft.Network` before provisioning. They register a
missing provider and wait for `Registered` with a ten-minute budget and at most
120 five-second polling waits per provider. An existing `Registering` state is
waited on without another registration request. Denied or incomplete registration
stops deployment explicitly; no missing-provider error is silently ignored.
An RG's metadata location need not equal its resources' region.

The shared capacity administrator is the **deployment principal's object ID**,
read from its existing ARM token's `oid` claim without Graph lookup or token
output. Participant IDs are rejected as capacity administrators. An authorized
Fabric administrator must still arrange workspace assignment permissions and
governance; ARM ownership does not imply Fabric workspace access.

### Enable participant workspace assignment after capacity provisioning

An authorized capacity administrator must configure **Fabric capacity Contributor
permissions**, not Azure IAM Contributor. Keep subscription Reader and
participant-RG Owner unchanged. Azure Reader does not grant Fabric assignment
rights; Azure Contributor would grant infrastructure management rather than the
intended workspace-assignment permission.

After the shared F16 is Active, and before admitting participants:

1. Sign into the lab tenant's Fabric portal as an authorized capacity administrator.
2. Open **Settings > Admin portal > Capacity settings > Fabric capacity**.
3. Select the exact shared capacity name returned by `shared-deploy-lab.ps1`.
4. Under **Details > Contributor permissions**, select **Specific users or
   security groups** and add the assigned lab users for that subscription, or an
   organizer-managed security group containing exactly those users.
5. Select **Apply**. Do not choose the entire organization or add participants
   under **Admin permissions**.
6. Have the Fabric tenant administrator verify that **Create workspaces** permits
   those identities. Confirm the participants have the required authoring
   entitlement and API consent.

A participant creates their own workspace in Challenge 1 and is its workspace
Admin. Together with capacity Contributor, this permits assignment to the F16.
For REST assignment, the delegated scopes are `Capacity.ReadWrite.All` and
`Workspace.ReadWrite.All`; Azure CLI/MCP authentication must use the assigned lab
Entra identity. Record an actual successful assignment in the pilot, not merely
an Azure role assignment or a visible capacity name.

This is an explicit organizer step, **not an automated grant by these hooks**.
The deployed ARM API exposes `administration.members` for capacity administrators,
not this contributor allow-list. No undocumented Fabric endpoint or capacity-admin
substitute is used. Apply this setting to the existing successfully deployed
capacity; it does not require resetting/rebuilding participant VMs. Repeat it for
each newly created subscription capacity.

References: [capacity Contributor permissions](https://learn.microsoft.com/en-us/fabric/admin/capacity-settings#details),
[tenant settings](https://learn.microsoft.com/en-us/fabric/admin/tenant-settings-index),
and [workspace assignment API permissions](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/assign-to-capacity).

## Infrastructure and private VM access

The shared hook provisions once per subscription:

- One F16 at `rg-apbi-shared-<hash(subscription)>`.
- A shared `10.90.0.0/16` VNet, a reserved `10.90.0.0/26` Bastion subnet,
  one stable-named `/26` per supplied participant, and explicit NAT egress.
- One Standard Azure Bastion and its public HTTPS endpoint. Participants connect
  from the Azure portal using their own VM credentials. No VM has a public IP.

The participant hook provisions a private NIC, NIC-level NSG, Windows VM and OS
disk in that participant's RG, then a managed Run Command for bootstrap.
The NSG allows RDP only from the Bastion subnet and denies all other inbound
traffic, including default VNet inbound. Shared subnets are created **before**
parallel participant fan-out, avoiding concurrent shared-VNet updates.

Bastion, NAT, public endpoint IPs, traffic, VM/disks and F16 all incur costs.
Two Bastion scale units and the address-plan ceiling of 1000 identities are
**not** a supported F16 cohort size. Measure the actual cohort and concurrent
notebook/desktop load. Change the reviewed scale/address plan if necessary.
The subnet roster is fingerprinted: adding/removing participants after deployment
requires explicit migration/rebuild review, not automatic subnet renumbering.

## Bootstrap and two independently configured agent hosts

`main.bicep` embeds the local `bootstrap.ps1` into managed Run Command. There is
no separately hosted bootstrap URL, source ZIP, seven-kilobyte shell argument or
requirement for custom portable bundles. Run Command waits for completion and
treats script failure as ARM deployment failure. Its configuration uses protected
parameters; it carries no participant/cloud authentication secrets.
Both Bicep secure-string inputs (VM password and bootstrap configuration) are
passed as native CLR `SecureString` values in `TemplateParameterObject`.
Their `PSObject` wrappers must be removed: PowerShell's `-is [securestring]`
alone accepts the wrapper, but Az's C# conversion can miss it and fail locally
with `Unable to serialize secure string value`, before any ARM deployment exists.

[student-files.json](student-files.json) lists 25 exact source files and hashes:
both sets of eight CSVs, manifest, dictionary, generator/module and five shared
brief/guidance files. They are fetched individually from immutable MicroHack
commit `679f03ec391f2b8adfac4b1fdf58878f8674c272`; coach files and the repository
archive are never downloaded. This intentionally pins the original dataset and
brief revision. Update the ref/descriptors together after publishing any source
change that should reach VMs. The selected bytes and manifest are verified.
Descriptor SHA256 values describe immutable **Git blob bytes**, not Windows
working-tree text after CRLF conversion. The VM also receives a generated
exercise README with current host and shared-resource cleanup guidance.

On the VM's first provisioning attempt, `resolve-packages.ps1` resolves the latest
stable Windows x64 PowerShell, MinGit, Node, VS Code, Copilot CLI, Azure CLI and
Python; stable Copilot/Chat VSIX packages; the current Fabric skills main commit;
and the stable report CLI version. Prereleases are excluded. It persists exact
URLs, versions/commit, available publisher digests and resolution time in
`C:\MicroHack\host\packages\packages.lock.json` **before installation**.
Retries use that record, not today's latest releases. If feeds, rate limits,
checksums or upstream layouts prevent resolution, provisioning fails explicitly;
there is no silent fallback to an old package set. Permit the official GitHub API,
Node, Python, VS Code, Marketplace/CDN and public Microsoft npm feed endpoints.
Pilot parallel provisioning against anonymous API/download limits.

Tools are fetched from official release hosts and checked before use: PowerShell,
MinGit, Node, VS Code and Copilot are ZIPs; Python uses its all-user installer and
Azure CLI its all-user MSI. Redirects to release CDNs are allowed, bounded, and
checked against publisher digests where supplied (GitHub assets, Node and VS Code).
Python, VSIX and the commit-addressed Fabric archive are acquired through official
HTTPS endpoints and their downloaded SHA256 values are frozen locally; these
recorded hashes are **not independently published checksum attestations**.
Cached bytes are checked on reuse. Extracted ZIPs reject
traversal, symbolic links, duplicate paths and excessive expansion. Tool versions
are checked after installation. Python and portable tools live under
`C:\MicroHack\tools`; Azure CLI uses its vendor's Program Files directory.

The report runtime creates its exact dependency lock once under
`C:\MicroHack\tools\report`, then uses `npm ci`, SHA512 integrity and disabled
lifecycle scripts. Its lock is retained for retries and inspection.
Microsoft's public npm feed can return SHA1-only dependency metadata. During
initial provisioning, those exact HTTPS archives are downloaded with bounded
timeouts/redirects and verified against the feed's SHA1. Their actual bytes are
then hashed with SHA512 and recorded atomically in the lock before `npm ci`.
The original checksum is retained as `microhackSourceIntegrity`. This SHA512 is
a locally computed first-acquisition hash, not a publisher-provided SHA512 or
signature; HTTPS and the feed's original checksum establish that acquisition.
Missing/unsupported checksums, mismatches and insecure redirects fail without
rewriting the lock. Already-frozen SHA512 entries do not need this extra download.

The checked-in [reference npm lock](npm-runtime/package-lock.json) describes the earlier locally
exercised toolchain, not the dynamically resolved VM runtime. No employee npm
credentials are required. New stable versions must still pass the event pilot;
"latest" is not a compatibility or live-acceptance claim.

The complete Fabric repository is staged under
`C:\ProgramData\MicroHack\skills-for-fabric\<commit>`, readable by all Windows
users and writable by SYSTEM/Administrators. The lab-adapted marketplace retains
both complete official `fabric-skills` and `powerbi-authoring` skill/agent bundles.
Their auxiliary MCP registrations are deliberately emptied in the staged copy:
some upstream entries launch `npx ...@latest`, which would break the frozen lab.
The original downloaded archive remains checksum-recorded in the package cache.
**Fabric Core is registered explicitly**, not assumed to ship with those bundles.

- **Copilot CLI:** each Windows profile registers the local marketplace and both
  plugins, plus `fabric-core` in `%USERPROFILE%\.copilot\mcp-config.json`.
- **VS Code Agent:** the full project skill/common/agent trees are staged under
  `C:\MicroHack\student\.github`; local Copilot and Chat VSIX files are installed
  in each interactive user's profile. `.vscode\mcp.json` configures Core separately.

Both point to `https://api.fabric.microsoft.com/v1/mcp/core`. No static tokens,
organizer credentials or shared authentication caches are installed. GitHub and
Entra identities are independent; using another GitHub account in the same Windows
profile does not change installed content. Different Windows profiles initialize
separately. User configuration merges preserve unrelated entries and back up
changed JSON atomically; conflicting marketplace/plugin/Core entries stop rather
than silently replacing personal settings.

Active Setup invokes `C:\MicroHack\initialize-user.ps1` on interactive login.
The **Start MicroHack CLI/VSCode** desktop shortcuts also run it, then open the
exercise folder. It only uses the frozen source and local VSIX files; it never
checks for a newer release. Interrupted setup retries missing components without
reinstalling successful bundles. A host-content hash inventory detects altered
snapshots. CLI automatic updates are disabled at machine/session level, plugin
updates in the user settings, and VS Code application/extension updates in each
user profile. Do not update manually. This does not disable OS security updates
or freeze Microsoft-hosted Fabric/MCP/GitHub services.

Configuration completion is recorded separately from authentication. Before
Challenge 1, **each supported host must successfully authenticate Core MCP with
the assigned lab Entra identity and execute a read-only workspace-list tool**.
Azure CLI login or an installed skill is not that proof. Complete delegated
consent/Conditional Access preflight without granting participants tenant admin.
CLI/REST tools remain available for unsupported authoring operations, but cannot
replace this MCP gate. Native Windows broker/`ENTRA_CONFIG` failures remain a
pilot blocker, not something fixed by configuration distribution.

This source change is for newly provisioned VMs. It does not update existing live
VMs: bootstrap/guest fingerprints intentionally reject changed configurations to
preserve student work. Arrange an explicit clean rebuild for the next pilot; no
live VM is upgraded or destroyed by authoring these files.

Both scenarios are at `C:\MicroHack\student\datasets`; briefs are at
`C:\MicroHack\student\briefs`. Open that exercise folder, not the source repository.
Run `python datasets\generate-data.py --validate` before Challenge 1.
Workspace creation/assignment remains the first learner task.

## Organizer release gates are not runtime configuration

Complete [organizer readiness](organizer-readiness.md) and the private evidence
behind [release gates](../resources/release-gates.md) before participant admission:
Fabric availability and assignment rights; enabled Power BI author service
plans/stock; Copilot seats/models; ItemCreation coverage for the four allowed
types, managed SQL endpoint and newly created workspaces; both host journeys;
VM/Bastion isolation; regional quota; measured F16 load; budget and cleanup.
No code here claims that Contributor permissions enforce allowed item types.
If enforcement is unavailable, stop admission until an explicit exception is
approved. No private approval flag is invented or silently set to true.

`Quality` remains `Testing`. The platform settings still need reviewed
`labsPerSubscription`, costs and any region overrides for the actual event. Omission is
not zero cost: platform defaults can use $25/day per participant and $0 shared,
which do not describe an F16 plus Bastion/NAT fleet. Approve actual estimates
and reimport the event settings before offering the lab to participants.
Reimport these defaults (or update the existing event's region setting) to apply
Switzerland North to an event created before this change; an already stored
region override is not replaced by the hook.
This does not relocate an existing deployment. Previously owned resources with
different configuration/region tags still require explicit migration or rebuild
review; do not delete or retag them just to bypass the ownership checks.

## Retries, ownership and diagnostics

Shared names are derived from subscription; participant names from lab version,
subscription, RG and identity. All owned resources carry configuration/ownership
tags. Empty participant RGs can be claimed while preserving platform tags;
foreign resources, configuration changes and a changed roster are rejected.
Implicit OS disks are tagged only after verifying their owning tagged VM.
No resource group recycling, destructive region fallback or automatic migration
is performed. Failed deployments are not returned as successful credentials.

A matching completed guest marker rechecks data and required tool presence.
An incomplete bootstrap retries its staging; an unmarked student directory or a
changed guest configuration blocks overwrite of learner work. A hook retry
changes Run Command's run token while preserving stable credentials.
Inspect sanitized ARM/Run Command status privately on failure. Do not enable
transcripts/debugging around credential output or serialize parameter objects.
Guest failures retain a timestamp, error message, error ID and script stack in
`C:\MicroHack\bootstrap-error.txt` for private VM-side diagnosis.
Without Windows VM credentials, an organizer with Azure VM Run Command permission
can open the VM's **Operations > Run command > RunPowerShellScript** in Azure portal
and run `Get-Content -LiteralPath 'C:\MicroHack\bootstrap-error.txt'`.
Review the output privately for credentials before sharing it; do not dump the
protected bootstrap configuration.

Windows PowerShell 5.1 cannot deserialize npm's empty root-package JSON key:
it reports an invalid argument named `name`. Report-lock validation therefore uses
the already-installed Node.js parser to project named package entries before
PowerShell checks the frozen report version and every dependency's HTTPS/SHA512
integrity. The empty root entry is not a downloaded dependency. This does not
change the selected package versions or relax the integrity checks.

Detailed hook diagnostics are enabled by default:

- `[lab]` records each Azure call's start, completion/failure and elapsed time,
  plus the deployment name, region, VM size and resolved image version.
- `[lab:arm]` records request paths without query values, HTTP status and attempts.
- `[lab:error]` records the error ID, exception types/messages, up to eight inner
  exceptions, provider error details and source filename/line. Local client,
  template compilation and validation failures are therefore visible even if
  ARM never records a deployment.
- `[lab:diagnostic]` and `[lab:operation]` attempt read-only deployment metadata
  and operation inspection after either a thrown deployment error or a failed
  result. They include correlation/request IDs, target resource IDs/types,
  states and status messages for up to 30 operations.

The collector does not redeploy, run guest commands or change resources. Missing
deployment records or denied diagnostic reads are logged without replacing the
original failure. Known VM passwords (including escaped forms), bootstrap
payloads, bearer/JWT tokens, credential fields and URL queries are redacted;
messages are capped at 3000 characters. Entire exception objects, request/response
objects, parameter objects and Az debug/verbose streams are not dumped.
Logs still contain infrastructure IDs and should be handled as organizer
diagnostic material. This instrumentation improves evidence; it does not prove
the cause of a previously suppressed error or fix an unidentified Azure failure.

The platform invokes shared first, waits, then invokes participant hooks. No
launcher environment customization is needed. The [offline tests](../tests/README.md)
invoke both full scripts with provider-boundary doubles, no private config,
two identities, reruns and explicit failure cases. They are not live cloud proof.

## Audience packaging

`contentPreparation` in `lab-defaults.json` removes the repository-only root
README, tests, contributor guide and `.gitignore` from both published sides;
the platform excludes `labautomation` itself. ZIP exclusions are configured
separately. Students use `challenges\README.md` for Home; coaches use
`walkthrough\README.md`. Parent-README banners are disabled, download banners
retained, and both audiences share `resources\cleanup.md`.
ZIPs omit top-level files and audience lesson Markdown; keep published lessons
open beside downloaded supporting source. Local package tests model this
contract; actual import, banners and downloads still need pilot inspection.
