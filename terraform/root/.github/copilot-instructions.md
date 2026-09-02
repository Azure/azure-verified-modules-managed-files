---
description: Instructions for discovering and applying Azure Verified Modules Terraform agents and skills.
---

# Azure Verified Modules Terraform

Before working on Terraform in this repository:

1. Read and follow [`AGENTS.md`](../AGENTS.md).
2. Fetch the current AVM documentation index from <https://azure.github.io/Azure-Verified-Modules/llms.txt>.
3. Read the complete skill matching the task before analyzing or changing files.
4. Use the [AVM Terraform agent](agents/avm-tf.agent.md) for specification-driven module development.

## Skills

| Skill | Use for | File |
| --- | --- | --- |
| `avm-tf-azapi` | AzAPI resources, ARM schemas, provider constraints, retries, timeouts, response exports, replacement triggers, and `ignore_body_changes`. | `.github/skills/avm-tf-azapi/SKILL.md` |
| `avm-tf-classifications` | Resource, pattern, and utility module classification and naming. | `.github/skills/avm-tf-classifications/SKILL.md` |
| `avm-tf-codestyle` | Terraform file layout, HCL style, variables, outputs, validation, and lifecycle syntax. | `.github/skills/avm-tf-codestyle/SKILL.md` |
| `avm-tf-documentation` | Generated README inputs, examples, and documentation validation. | `.github/skills/avm-tf-documentation/SKILL.md` |
| `avm-tf-interfaces` | Standard AVM interfaces and utility-module composition. | `.github/skills/avm-tf-interfaces/SKILL.md` |
| `avm-tf-lifecycle` | Module proposal, ownership, lifecycle, versioning, and deprecation. | `.github/skills/avm-tf-lifecycle/SKILL.md` |
| `avm-tf-migration` | AzureRM-to-AzAPI migration and state-preserving changes. | `.github/skills/avm-tf-migration/SKILL.md` |
| `avm-tf-process` | Contribution flow from repository setup through validation, pull request, and release. | `.github/skills/avm-tf-process/SKILL.md` |
| `avm-tf-submodules` | Child-resource submodule structure and composition. | `.github/skills/avm-tf-submodules/SKILL.md` |
| `avm-tf-telemetry` | AVM telemetry resources, inputs, and AzAPI headers. | `.github/skills/avm-tf-telemetry/SKILL.md` |
| `avm-tf-testing` | Unit, integration, E2E, hooks, and CI testing. | `.github/skills/avm-tf-testing/SKILL.md` |
| `avm-tf-tflint` | Current AVM TFLint rules, canonical rule IDs, severity, overrides, scope, and precedence. | `.github/skills/avm-tf-tflint/SKILL.md` |
