# Organizer readiness

The [deployment guide](README.md) describes the supplied nonsecret settings,
provisioning-time frozen assets, private Bastion access and two host configurations.
No custom environment injection or private event JSON file is required.
Infrastructure provisioning is distinct from permission to admit learners.

Before delivery, record private evidence for:

- Enabled Power BI author service plans and seat stock for each identity, plus
  Copilot seats, permitted models and usage budget. F16 alone is not a license.
- Fabric **capacity Contributor** permissions for the assigned lab users or their
  scoped security group, configured by a capacity administrator after F16 creation.
  Follow the [capacity permission setup](README.md#enable-participant-workspace-assignment-after-capacity-provisioning).
  Azure subscription Reader is unchanged; Azure IAM Contributor is not a substitute.
  Confirm the tenant's Create workspaces setting includes those identities and
  verify a pilot participant can create their own workspace and assign it to the
  correct capacity as workspace Admin. REST assignment requires
  `Capacity.ReadWrite.All` and `Workspace.ReadWrite.All` delegated scopes.
- Supported ItemCreation
  policies for Lakehouse, Notebook, SemanticModel and Report. Verify the managed
  SQL endpoint dependency and coverage for new workspaces. Do not grant capacity
  admin to participants or pretend instructions enforce allowed types.
- Region/VM SKU availability, quotas and Azure Policy, Windows Server license
  inclusion, outbound download hosts and working browser Bastion connections.
  Windows client images/Hybrid Benefit are not enabled by these defaults.
- Correct source pin/policy from `lab-settings.psd1`, the VM's resolved
  `host\packages\packages.lock.json`, downloaded hashes, installed runtime/VSIX
  versions and `tools\report\package-lock.json`. Distinguish publisher checksums
  from locally recorded first-download hashes. Validate both complete Fabric
  bundles, shared references and anonymous metadata/download limits under fan-out.
- First-login initialization and complete three-challenge journeys through
  **each host separately**. Confirm tools actually start, skills are discovered,
  interactive Fabric/Power BI authentication works with the required token
  audiences, Spark executes, DAX reconciles and report rendering/filters work.
- Mandatory Fabric Core MCP discovery, assigned Entra identity/tenant selection,
  delegated consent/Conditional Access and a successful read-only workspace-list
  tool call **before Challenge 1 in both hosts**. GitHub authentication and Azure
  CLI tokens do not authenticate the MCP connection. Resolve native Windows
  broker errors before admission; do not claim that staged JSON fixes them.
- Two Windows profiles receive the same frozen bundles without shared credentials;
  repeated launches/repairs do not resolve new versions or overwrite unrelated
  configuration. Verify CLI/plugin and VS Code updates remain disabled throughout
  the pilot. Record configuration readiness separately from MCP authentication.
- Two-identity isolation for Windows credentials, VM reachability and Fabric
  workspace/data access. Shared subscription Reader reveals infrastructure
  metadata; it is not data/workspace isolation.
- Measured F16 concurrency, Bastion load, actual VM/F16/Bastion/NAT/IP/storage/
  egress/license costs, retention and cleanup. Approve platform estimates and
  cohort settings before participant admission; no measured envelope is supplied.

Retain source ref, dataset hashes, image version, tools/skills/extensions,
approved model, schemas, timestamps and assertion-specific results privately.
Follow the [release ledger](../resources/release-gates.md) and obtain independent
review before promotion from Testing. Do not fill missing evidence with a default
approval or treat offline tests/provider metadata as live acceptance.

Give learners their identity, capacity information, workspace naming guidance,
the approved version/model record and support route. They follow
[participant readiness](../resources/host-readiness.md), verify the supplied VM,
sign in interactively and start workspace creation in Challenge 1.
