/**
 * Creates the release for a pushed version tag with a correct identity, or
 * corrects the flags on one that already exists.
 */

import * as core from "@actions/core";
import * as github from "@actions/github";

import {
  claimsLatest,
  isBounded,
  isFinal,
  notesBase,
  parseTag,
  rank,
  type Tag,
} from "./identity.js";

type Octokit = ReturnType<typeof github.getOctokit>;

/**
 * Every version tag needed to decide `pushed`'s identity, in ascending order.
 *
 * Tags come from the API, so the action needs no checkout. Identity is decided by
 * comparing the pushed tag against the others, and a shallow checkout would
 * narrow that comparison into a plausible wrong answer with nothing to detect it.
 *
 * Every version tag is a candidate boundary, including test and personal ones:
 * excluding those would make the base depend on who cut the surrounding tags.
 *
 * The whole page is consumed before stopping rather than only up to the first
 * lower tag, because the order within a page is the API's and not a version
 * ranking: it places a version's final after its own candidates, and sorts v100
 * above v99. Tag dates are not consulted either, since tags are routinely cut out
 * of chronological order, nor is commit ancestry: most release tags are
 * unreachable from the default branch.
 */
export async function collectTags(
  octokit: Octokit,
  owner: string,
  repo: string,
  pushed: Tag,
  maxPages: number,
): Promise<Tag[]> {
  const collected: Tag[] = [];

  for (let page = 1; page <= maxPages; page += 1) {
    const { data } = await octokit.rest.repos.listTags({
      owner,
      repo,
      per_page: 100,
      page,
    });
    if (data.length === 0) {
      return rank(collected);
    }
    for (const { name } of data) {
      const tag = parseTag(name);
      if (tag) {
        collected.push(tag);
      }
    }
    if (isBounded(collected, pushed)) {
      return rank(collected);
    }
  }

  throw new Error(
    `Reached the ${maxPages}-page tag listing limit for ${owner}/${repo} ` +
      "without finding a version below the pushed tag. Refusing to pick a " +
      "notes base from a partial tag list.",
  );
}

/** The commit a tag names, or null when it names none. */
function commitLookup(
  octokit: Octokit,
  owner: string,
  repo: string,
): (tag: Tag) => Promise<string | null> {
  return async (tag) => {
    try {
      const { data } = await octokit.rest.git.getRef({
        owner,
        repo,
        ref: `tags/${tag.name}`,
      });
      if (data.object.type !== "tag") {
        return data.object.sha;
      }
      const { data: annotated } = await octokit.rest.git.getTag({
        owner,
        repo,
        tag_sha: data.object.sha,
      });
      return annotated.object.sha;
    } catch {
      return null;
    }
  };
}

export async function run(): Promise<void> {
  const name = github.context.ref.replace(/^refs\/tags\//, "");
  const pushed = parseTag(name);
  if (!pushed) {
    core.setFailed(
      `${name} is not a version tag; expected two or three dot-separated ` +
        "numbers, as v1.2 or v1.2.3, optionally followed by -rc<n> and a suffix",
    );
    return;
  }

  const octokit = github.getOctokit(core.getInput("token", { required: true }));
  const { owner, repo } = github.context.repo;
  const maxPages = Number(core.getInput("max_pages") || "20");

  const tags = await collectTags(octokit, owner, repo, pushed, maxPages);
  const base = await notesBase(tags, pushed, commitLookup(octokit, owner, repo));

  const prerelease = !isFinal(pushed);
  const latest = claimsLatest(tags, pushed);

  core.setOutput("latest", String(latest));
  core.setOutput("notes_start", base?.name ?? "");
  core.setOutput("prerelease", String(prerelease));

  // Both flags are stated on every call. "Latest" is three-state on the release
  // API: omitting it is not the same as declining it, and the fallback is publish
  // order.
  const flags = {
    owner,
    repo,
    prerelease,
    make_latest: (latest ? "true" : "false") as "true" | "false",
  };

  const existing = await findRelease(octokit, owner, repo, name);
  if (existing !== null) {
    // Correcting an existing release with a call that also names the tag is
    // rejected as `already_exists`, and the rejection takes any attached asset
    // with it. Editing the flags as named fields leaves the rest of the release
    // alone.
    await octokit.rest.repos.updateRelease({ ...flags, release_id: existing });
    core.info(`Corrected ${name}: prerelease=${prerelease} latest=${latest}`);
    return;
  }

  try {
    await octokit.rest.repos.createRelease({
      ...flags,
      tag_name: name,
      name,
      generate_release_notes: true,
      // An empty boundary is not the same as no boundary: it would widen the
      // notes to the entire history.
      ...(base ? { previous_tag_name: base.name } : {}),
    });
    core.info(
      `Created release ${name}: prerelease=${prerelease} latest=${latest} ` +
        `notes base=${base?.name ?? "<none>"}`,
    );
  } catch (error) {
    // Another job pushing the same tag may have won the race. Its release is the
    // one this run wanted, so reconcile the flags onto it rather than failing.
    const raced = await findRelease(octokit, owner, repo, name);
    if (raced === null) {
      throw error;
    }
    await octokit.rest.repos.updateRelease({ ...flags, release_id: raced });
    core.info(`Corrected ${name}: prerelease=${prerelease} latest=${latest}`);
  }
}

/** The release for a tag, or null when there is none. */
export async function findRelease(
  octokit: Octokit,
  owner: string,
  repo: string,
  tag: string,
): Promise<number | null> {
  try {
    const { data } = await octokit.rest.repos.getReleaseByTag({
      owner,
      repo,
      tag,
    });
    return data.id;
  } catch {
    return null;
  }
}

run().catch((error: unknown) => {
  core.setFailed(error instanceof Error ? error.message : String(error));
});
