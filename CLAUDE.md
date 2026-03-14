This is an Elixir application

You MUST do the following:

- Every feature must be TDD'd
- Included in each set of changes must be any necessary changes or additions to the README.md file

## Release Process

When the user says "release" (or similar), follow this procedure:

### 1. Determine the version

- If the user specifies a version, use it.
- *MUST* read the current version from `mix.exs` first and treat that source-code version as the canonical baseline for the next release. Do not derive the baseline version from git tags, commit messages, or GitHub releases when they disagree with the source tree.
- Do not bump to a new major version while the project is still on `0.x` unless the user explicitly instructs you to start a `1.x` (or higher) release. When the project is still on `0.x`, default to the appropriate `0.x` bump even if the changes would normally look "major" under full SemVer.
- Otherwise, analyze the unreleased commits since the last release commit/tag that matches the source-code version lineage and apply [Semantic Versioning](https://semver.org/):
  - **patch** (0.0.x): bug fixes, docs, test-only changes, or dependency updates
  - **minor** (0.x.0): new features, new public modules/functions, or non-breaking enhancements
  - **major** (x.0.0): breaking changes to public APIs, configuration, or runtime behavior
- If tags or history suggest a higher version than `mix.exs`, treat that as drift to be corrected instead of as the next release baseline.

### 2. Update version string

Update the version in the single source of truth:
- `mix.exs` — `version: "X.Y.Z"`

If any generated docs, package metadata, or examples duplicate the version, update them too, but `mix.exs` is the canonical source.

### 3. Review and update README.md

Ensure the README accurately reflects the current state of the project:
- New public APIs or features are documented
- Removed or renamed features are cleaned up
- Installation instructions are current
- Configuration examples use the current option names and env vars
- Examples and usage sections match the actual library behavior

### 4. Update CHANGELOG.md

Follow [Keep a Changelog](https://keepachangelog.com/):
- Create `CHANGELOG.md` if it does not exist yet
- Add a new `## [X.Y.Z] - YYYY-MM-DD` section below `## [Unreleased]` (or below the header if no Unreleased section exists)
- Categorize changes under: Added, Changed, Deprecated, Removed, Fixed, Security
- Add a link reference at the bottom: `[X.Y.Z]: https://github.com/DockYard/flame_on_client/releases/tag/vX.Y.Z`
- Each entry should be a concise, user-facing description (not a commit message)

### 5. Commit, tag, and push

```sh
git add mix.exs README.md CHANGELOG.md
git commit -m "Release X.Y.Z"
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

If the project publishes to Hex or relies on GitHub Actions for release automation, ensure the release commit and tag are pushed so the existing workflow can run.
