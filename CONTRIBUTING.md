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

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of
Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion
or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those
third-party's policies.
