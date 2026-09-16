# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

Composite actions shared across BuoySoftware's repositories, so the same CI
steps are written once rather than per repository. For the mechanics, see
GitHub's guide on
[creating a composite action](https://docs.github.com/en/actions/tutorials/create-actions/create-a-composite-action).

## Changes here are shared

A change runs in every consuming repository, across whichever package managers
and configurations they use. Prefer additive changes, and check every branch of
an action you touch rather than only the one you happen to use.

Consumers pin a commit SHA, so merging alone ships nothing. The README covers
releasing.

## This repository is public

Do not name the repositories a change was written for or verified against.
Describe them by the property that matters instead, such as a repository using
Yarn Berry with the node-modules linker. Also keep out secret or token values,
environment and infrastructure detail, internal URLs, ticket keys and anything
about customers. This applies to commit messages and pull request descriptions
as much as to code.

## Style

Comments only where the code cannot say it.
