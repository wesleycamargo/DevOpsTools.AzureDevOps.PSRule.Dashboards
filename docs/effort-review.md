# Proposed remediation effort

These are draft rule-level estimates for owner review, based on the remediation
described by the rule catalog. They are not configured in the dashboard. They
describe a typical change to one affected resource, not the total effort to fix a
project. Resource count, team coordination and dependencies can increase effort.
No organization names, resource identities or assessment results are included.

- **Low:** localized documentation or configuration work with an established owner
  and no expected integration change.
- **Medium:** workflow, permission or pipeline changes needing coordination and
  validation with consumers.
- **High:** migration or integration changes across systems needing staged rollout.
- **Unknown:** dependencies or the intended remediation are not established.

Severity measures the reported risk; it does not determine effort. No numeric
scores or delivery-time promises are assigned. Prefer explicit rule overrides to
category defaults.

| Rule | Proposed effort | Assumption / review needed |
| --- | --- | --- |
| `Azure.DevOps.ServiceConnections.Description` | Low | Owner can describe the existing purpose and scope accurately. |
| `Azure.DevOps.Pipelines.Environments.Description` | Low | Environment purpose and ownership are already known. |
| `Azure.DevOps.Tasks.VariableGroup.Description` | Low | Owner can document usage without including secret values. |
| `Azure.DevOps.Repos.Readme` | Low | Repository purpose and basic usage are known; broader documentation work is separate. |
| `Azure.DevOps.Repos.DefaultBranchPolicyMinimumReviewers` | Medium | Review workflow and reviewer availability are agreed; validate the affected branch workflow. |
| `Azure.DevOps.Repos.DefaultBranchPolicyResetVotes` | Medium | Team agrees when approvals expire; validate interaction with existing policies. |
| `Azure.DevOps.Repos.DefaultBranchPolicyRequireBuild` | Unknown | Medium if a reliable validation pipeline already exists; otherwise its creation and dependencies need assessment. |
| `Azure.DevOps.Repos.InheritedPermissions` | Unknown | Access inventory, group ownership and consumer dependencies are needed before estimating safe permission changes. |
| `Azure.DevOps.ServiceConnections.InheritedPermissions` | Unknown | Identify pipeline consumers and required privileges before estimating. |
| `Azure.DevOps.ServiceConnections.ClassicAzure` | High | Replacing a legacy connection requires consumer inventory, an agreed replacement and staged pipeline validation. |
| `Azure.DevOps.ServiceConnections.WorkloadIdentityFederation` | Unknown | Confirm connection eligibility, identity ownership and consumer compatibility before choosing Medium or High. |
| `Azure.DevOps.Tasks.VariableGroup.NoPlainTextSecrets` | Unknown | Confirm credential exposure, rotation dependencies, secret-store ownership and consumers; a secret flag alone is not a complete remediation. |
| `Azure.DevOps.Pipelines.Core.UseYamlDefinition` | High | Existing build behavior must be inventoried, migrated and validated before retiring the old definition. |
| `Azure.DevOps.Repos.GitHubAdvancedSecurityEnabled` | Unknown | Licensing, ownership, policy applicability and pipeline integration must be established first. |

Start review with controls listed under **Shared opportunities** so one reviewed
rule estimate can apply across projects. Check assumptions against a representative
affected resource with its owner. After review, add the exact rule name to
`config/effort.json` → `ruleOverrides` as Low, Medium or High. Keep explicit Unknown
where context is unresolved. Re-run the report to activate the estimate and its
provenance. Do not use these proposals as broad category defaults.
