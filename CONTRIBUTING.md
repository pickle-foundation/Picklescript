## Contributing

Contributions to PickleScript are welcome! Whether you're fixing bugs, improving existing features, adding new functionality, or improving documentation, every contribution is appreciated.

Please keep contributions focused, follow the existing coding conventions, and ensure your changes are properly tested before submitting a pull request.

If you're planning a major change, consider opening an issue first to discuss the proposed approach.

## Versioning and releases

PickleScript follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).
The version has exactly one source of truth: `compiler/version.pkl`. The CLI
`--version` output and the package manager's `User-Agent` read that constant;
do not hard-code a version anywhere else.

- Release versions use `MAJOR.MINOR.PATCH`.
- Development versions use a pre-release identifier such as `0.2.0-dev.1`.
  They are not tagged or published.
- Releases are annotated tags named `v<version>`, for example `v0.1.0`.
- Record user-visible changes in `CHANGELOG.md` under `Unreleased`.

To cut a release:

1. Move the `Unreleased` entries into a new version section with the release
   date.
2. Set `VERSION` in `compiler/version.pkl` to the release version.
3. Run the qualification battery (`tools\battery_lite.ps1`, and the full
   battery for a release).
4. Commit as `chore(release): v<version>`, create the annotated tag
   `v<version>`, and push the commit and tag.
