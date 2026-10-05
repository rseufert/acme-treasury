# GitHub settings

This repository is held to the settings the mocks are kept at, and the reasons
for each are written once, in
[mock-bank's `docs/GITHUB.md`](https://github.com/rseufert/mock-bank/blob/main/docs/GITHUB.md).
That file is not copied here: a fourth copy is a fourth place for it to drift.
What follows is only where this repository differs, and why.

| Setting | Here | Why it differs |
| --- | --- | --- |
| `pypi` and `testpypi` environments | none | Nothing is published. This is run from a checkout. If it is ever registered as a Julia package, releasing gets a section here first. |
| Actions allowed | `selected`: GitHub's own, and `julia-actions/setup-julia` | There is no publish action to allow. Julia is not in the runner's tool cache, so one third-party action installs it. It is pinned to a commit SHA in `ci.yml`, it runs with `contents: read` and nothing else, and Dependabot keeps the pin current. |
| Dependabot | `github-actions` only | The Julia packages are pinned by the two `Manifest.toml` files and updated by hand. |
| Merge method | squash | As `mock-bank` and `mock-acme`. Merge commits and rebase merges are switched off. |
| `no changelog` label | present, unused | There is no changelog here to ask for an entry. The label exists because the shared set of labels is the same everywhere, and Dependabot's pull requests carry it. |

Everything else is as that file says: the `main` ruleset with no deletion, no
non-fast-forward and the one required check, `CI passed`; the `v*` tag
ruleset; delete branch on merge, auto-merge and update branch on; secret
scanning with push protection; Dependabot security updates; wiki and projects
off; `GITHUB_TOKEN` read by default.

The required check means a push straight to `main` is refused, so every change
is a branch and a pull request.

## Checking it

```bash
r=acme-treasury
gh api repos/rseufert/$r --jq '"squash=\(.allow_squash_merge) commit=\(.allow_merge_commit) rebase=\(.allow_rebase_merge)",
  "automerge=\(.allow_auto_merge) delbranch=\(.delete_branch_on_merge) updatebranch=\(.allow_update_branch)"'
gh api repos/rseufert/$r/rulesets --jq '.[] | "ruleset: \(.name) target=\(.target) \(.enforcement)"'
gh api repos/rseufert/$r/actions/permissions --jq '"actions: \(.allowed_actions // "all")"'
gh api repos/rseufert/$r/actions/permissions/selected-actions --jq '.patterns_allowed'
```
