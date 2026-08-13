# Azure Verified Modules - Managed Files

Files that are synced out to Azure Verified Modules (AVM) module repositories.

## Layout

| Path | Purpose |
| --- | --- |
| `terraform/<fileGroup>/` | File overlays. `root` applies to every module repository; the others stack on top for repositories mapped to that group. |
| `terraform/<fileGroup>/_config.json` | Reserved per-group config. Never synced. Declares the group `description` and, optionally, `deletedFiles` and `managedLines`. |
| `scripts/` | Validation scripts, shared across all languages. |

Every file in a group folder is synced to the target repository except
`_config.json` at the group root. A nested `_config.json` deeper in the tree is
treated as ordinary content and is synced.

`_config.json` keys:

| Key | Required | Purpose |
| --- | --- | --- |
| `description` | Yes | Explains what the group is for. Read by people, ignored by the sync engine. |
| `deletedFiles` | No | Paths that must not exist in the target repository. Overrides files contributed by lower-order groups. |
| `managedLines` | No | Per-file line specs. Maps a relative path to `required` and `removed` line arrays, for files the target repository also owns (for example `.gitignore`). |

Which repositories receive which file group is defined by `repositoryGroups` in
[`azure-verified-modules-tools`](https://github.com/Azure/azure-verified-modules-tools).

Overlays stack in ascending group `order`, so a higher-order group wins for
duplicate paths. A path listed in a group's `deletedFiles` overrides any
file contributed by a lower-order group and is deleted from the target
repository.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
