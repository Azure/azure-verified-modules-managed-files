# Azure Verified Modules - Managed Files

Files that are synced out to Azure Verified Modules (AVM) module repositories.

## Layout

| Path | Purpose |
| --- | --- |
| `terraform/files/<fileGroup>/` | File overlays. `root` applies to every module repository; the others stack on top for repositories mapped to that group. |
| `terraform/config/managed-files.json` | Declares the file groups and, per group, the paths that must not exist in the target repository. |
| `terraform/scripts/` | Validation scripts for the managed file content. |

Which repositories receive which file group is defined by `repositoryGroups` in
[`azure-verified-modules-tools`](https://github.com/Azure/azure-verified-modules-tools).

Overlays stack in ascending group `order`, so a higher-order group wins for
duplicate paths. A path listed in a group's `deletedFiles` overrides any
file contributed by a lower-order group and is deleted from the target
repository.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
