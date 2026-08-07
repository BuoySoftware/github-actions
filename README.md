# github-actions

This repository is a compilation of GitHub Workflow Actions we use across our
repositories.

## Releasing a change

Consumers pin these actions to a commit SHA, with the tag named in a trailing
comment (`uses: BuoySoftware/github-actions/<action>@<sha> # v1.0.1`). Merging
to `main` does not reach them: a change ships only when a `vX.Y.Z` tag is cut
on the merged tip.

```sh
git tag v1.0.2 origin/main
git push origin v1.0.2
```

Dependabot in the consuming repositories watches the tags and raises a pin-bump
PR within a day. A change that must land together with a consumer-side edit
should not wait for that: bump the pin in the consumer's own PR, pointing at
the new tag's SHA.

Tags are never moved or deleted once pushed — cut a new one instead.

## How to create a new action

If you are interested in creating a new shared composite action, a good place to
start is reading the [GitHub
guide](https://docs.github.com/en/actions/creating-actions/creating-a-composite-action)

