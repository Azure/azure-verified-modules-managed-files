# Contributing

This project welcomes contributions and suggestions. Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the
instructions provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/)
or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or
comments.

## Changing managed files

Every file under `terraform/files/` is copied verbatim into the AVM module repositories that are
mapped to that file group, so a change here lands in many repositories at once.

- Add a file to `terraform/files/root/` to ship it to every module repository.
- Add a file to a non-`root` group to ship it only to repositories mapped to that group.
- To stop shipping a file, remove it and add its path to that group's `deletedFiles` in
  `terraform/config/managed-files.json` so it is also deleted from repositories that already
  have it.
- To keep a `root` file out of one group, add its path to that group's `deletedFiles`.
  A `deletedFiles` entry overrides any file contributed by a lower-order group.

Repository-to-group mapping lives in
[`azure-verified-modules-tools`](https://github.com/Azure/azure-verified-modules-tools).

## Changing issue triage release verification

The new release gate is staged in `terraform/canary-ring-0/.github/workflows/`. That overlay targets only `Azure/terraform-azurerm-avm-ptn-example-repo` under the approved tools repository mapping. Ring 1 and fleet promotion require separate approval. Do not change cohort membership or copy this pair into root as part of staging.

The root Markdown and lock retain the exact published `v1.0.29` bytes. This includes restoring the unreleased release-ancestry changes from PR #49, not just moving PR #50's gate. Other overlays must neither replace nor delete either file.

Edit `terraform/canary-ring-0/.github/workflows/issue-triage.md`, then regenerate only its lock with `gh aw` v0.85.4:

```powershell
gh aw compile ./terraform/canary-ring-0/.github/workflows/issue-triage.md
./scripts/Test-IssueTriageIsolation.ps1
./scripts/Test-IssueTriageReleaseStatus.ps1
./scripts/Test-IssueTriageReleaseStatus.ps1 -WorkflowPath ./terraform/canary-ring-0/.github/workflows/issue-triage.lock.yml
```

The release regression script requires PowerShell 7.4+, Bash, jq, and timeout. Ubuntu runners provide these tools; Windows can use Git Bash with jq on its PATH. Fixtures replace `gh` and execute the actual workflow shell without network access. They cover ancestry summaries beyond 250 commits, missing or misleading message references, merge results, release branches, pagination, API failures, evidence vetoes, and lookup budgets.

The output-gate fixtures also require Node and the pinned gh-aw runtime scripts. The validation workflow prepares those scripts with `github/gh-aw-actions/setup` at the same v0.85.4 commit as the compiled triage workflow. Set `$runtimeDirectory` to that setup destination, then run:

```powershell
./scripts/Test-IssueTriageSafetyGate.ps1 -RuntimeDirectory $runtimeDirectory
./scripts/Test-IssueTriageSafetyGate.ps1 -RuntimeDirectory $runtimeDirectory -WorkflowPath ./terraform/canary-ring-0/.github/workflows/issue-triage.lock.yml
```

These fixtures exercise the actual gate with mocked GitHub calls. They cover direct close/label bypass attempts, exact-PR binding, trusted artifact integrity, newly discovered fixes, failed verification, preserved duplicate handling, and truthful blocked-action comments. The validation workflow runs both suites against the canonical and compiled overlay. The isolation assertion checks stable root bytes and rejects competing overlays, deletions, or line edits to the pair.

Ubuntu CI checks compatibility with the runner's Bash and jq versions. Local runs with newer tools do not replace that check.

Release proof uses each merged PR's post-merge commit, not a commit-message PR-number list. A positive result names a containing published stable release, not necessarily the first one. Divergent histories stay unknown unless another release proves inclusion; cherry-picked content is not automatically equivalent to the PR's merge result.

The initial candidate list guides discovery and screening; it does not limit which fixing PR can be verified. Before native output handlers run, trusted code checks the exact PR identified in the mandatory comment's structured decision. A fresh successful lookup can authorize a fix that the initial search missed. Missing or failed final verification cannot be replaced by another PR's release status, an initial positive result, or the model's own Git commands.

The verifier and discovery evidence come from a separate trusted job. The gate independently downloads their artifact by its captured ID and verifies the manifest and file hashes before use. Partial reruns may reuse a successful producer's snapshot, bound to that producer's recorded attempt; they still perform fresh release verification. Never load authorization or executable code from the agent's artifact. The gate's comments report requested, authorized, or blocked actions; native handler results record whether GitHub actually applied them.

The model must still establish that the PR fixes the issue and honor the human-reopen and incomplete-screening vetoes. Code can enforce release proof and declared screening coverage, not prove semantic relevance. Compiler or runtime upgrades must rerun the source and compiled fixtures, including the generated schema and gate-order assertions.

Native targets accept positive safe integers or canonical decimal strings, such as `291` and `"291"`. The gate rejects whitespace, leading zeroes, fractions, signs, suffixes, booleans, unsafe integers, and conflicting targets. This is intentionally narrower than the v0.85.4 native `temporary_id.cjs` parser. Decision fields, inspection lists, duplicate references, and proof PR identities still require typed integers.

`screened_inventory_prs` records every inventory row actually screened, including irrelevant rows. `fully_inspected_prs` records the smaller set whose real diffs and supporting evidence were inspected, plus any selected fix outside the index. The prompt provides a missing-work comparison, not automatic declarations. The gate reports missing PR numbers and retains the incomplete-screening veto.

Captured fixtures under `scripts/fixtures/issue-triage/` preserve the original requested outputs and trusted indexes from example-repository runs `34524301967` (B290) and `34525229100` (C291). B290 must remain blocked with 44 of 47 inventory rows undeclared. C291 must admit its unchanged string-target request for fresh PR #56 proof. API responses in these fixtures are mocks; passing them is not a new sandbox acceptance result. Later sandbox runs must still cover awaiting release, outside-index fixes, genuine final-proof failure, raw bypass attempts, first closure, human reopen, duplicates, and ordinary outputs.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion
or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those
third-party's policies.
