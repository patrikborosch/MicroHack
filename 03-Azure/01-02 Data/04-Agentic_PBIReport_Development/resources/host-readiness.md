# Participant VM and Copilot readiness

Complete this checklist on the **prepared VM before Challenge 1**. You verify the
environment; the organizer installs/pins tools, prepares both host configurations,
checks licensing/permissions and pilots the journey beforehand. Do not repair
missing packages, change tenant settings or update the event image yourself.

## Check your files and tools

- Use **Start MicroHack CLI** or **Start MicroHack VSCode** on the desktop.
  The shortcut prepares your Windows profile from the VM's frozen local snapshot,
  then opens `C:\MicroHack\student`. First login also attempts this setup.
  Both scenario
  CSV folders, `manifest.json`, `dictionary.md` and generator scripts must be under
  `datasets`; business/design briefs are under `briefs` on the VM. The platform's
  Student download instead keeps supporting briefs under `resources`.
- Connect to your private VM through the Azure portal's **Connect > Bastion**
  page using the VM credentials provided by the lab platform. A public VM IP or
  personal RDP source-range registration is not required.
- From that exercise folder, run `python datasets\generate-data.py --validate`.
  This reads and verifies both scenarios without changing files. Stop and ask the
  coach if files are absent or validation fails; do not regenerate over bad inputs.
- Check the supplied Git, Python, Node, Azure CLI, Copilot, VS Code and
  PowerShell 7 and `powerbi-report-author` commands against the organizer's
  provisioning record at `C:\MicroHack\host\packages\packages.lock.json`.
  Report a missing tool or version mismatch rather than installing `latest`.

## Sign in and verify your chosen host

- **Copilot CLI (primary):** sign in as yourself, choose the approved available
  model, check your permitted usage budget, and inspect active authoring skills
  and CLI tools. Confirm that both `fabric-skills` and `powerbi-authoring` plugins
  are enabled and that `spark-cli`, `semantic-model-authoring` and
  `powerbi-report-cli` are discoverable.
  If the coach asks you to run `C:\MicroHack\initialize-user.ps1`, review it first;
  it registers the frozen local bundles, merges Fabric Core MCP configuration and
  installs/verifies the local VSIX files in your profile. It never fetches a newer
  release. Existing unrelated settings are preserved; conflicts stop explicitly.
- **VS Code Agent (alternative):** open the exercise folder, sign in, select Agent
  mode and the approved model, and inspect project skills and authoring commands.
  CLI plugin installation alone does not configure VS Code.
- **Fabric Core MCP is required before Challenge 1, in either host.**
  Find the `fabric-core` server at
  `https://api.fabric.microsoft.com/v1/mcp/core`, approve the normal host trust/
  connection prompts, sign in with your assigned lab Entra identity and execute
  a read-only workspace-list tool call. An empty permitted workspace list is
  acceptable; workspace creation still belongs in Challenge 1.
  Merely seeing a configured server is not a successful connection.
- GitHub/Copilot sign-in and Fabric MCP sign-in are separate. A personal GitHub
  account can use the assigned lab identity for Fabric if its Copilot entitlement
  is approved. Changing GitHub accounts within the same Windows profile does not
  reinstall skills; a different Windows account receives its own configuration.
  Azure CLI sign-in does not authenticate the MCP connection.
- Authenticate to Fabric/Power BI CLI/REST tools separately where required.
  Never share or print tokens. Opening the portal or acquiring a Fabric token does
  not prove Power BI query entitlement; ask the coach about authentication errors.
  CLI/REST authoring complements Core MCP; it does not waive the MCP readiness gate.
- If native MCP sign-in fails (including Windows `ENTRA_CONFIG`/broker errors),
  stop and involve the coach. Do not copy tokens into JSON, share caches or disable
  authentication checks. A successful configuration initializer does not mean
  Fabric authentication passed, and the alternative host needs its own pilot.

## Confirm scope with the coach

Confirm your supplied capacity ID, workspace alias, workspace-creation and
capacity-assignment permissions, and enabled authoring entitlement. **F16 alone
does not supply a Power BI authoring license.** Shared deployment grants your
assigned lab identity capacity Admin. Do not change shared capacity settings or
permissions, or create a capacity, identity or license.

Read the [banking](banking-business-brief.md) or
[insurance](insurance-business-brief.md) brief and the
[dictionary](../datasets/dictionary.md). Workspace creation begins in Challenge 1;
it is not a preflight task. Manual Fabric experimentation is permitted within
the same approved scope. Stop for unresolved readiness failures.
