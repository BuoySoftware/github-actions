/**
 * Ranking of version tags, and the release identity derived from it.
 *
 * Kept apart from the action entry point so it can be tested without a runner,
 * an API or a token.
 */

/** A parsed version tag, ordered by its numbers and then its ordinal. */
export interface Tag {
  name: string;
  /**
   * The dot-separated numbers, held by position rather than by name: what each
   * position means differs between repositories while the ranking does not. An
   * absent third number counts as zero, so `v2.2` and `v2.2.0` are one version.
   */
  version: [number, number, number];
  ordinal: number;
}

/**
 * Two or three dot-separated numbers, an optional release-candidate ordinal, and
 * an optional collision-avoidance suffix.
 *
 * The leading `v` is required. It is what separates the current scheme from the
 * retired `YYYYMMDD.N` one, whose tags would otherwise parse as versions with a
 * leading number in the millions and outrank every real release.
 */
const TAG_PATTERN =
  /^v(\d+)\.(\d+)(?:\.(\d+))?(?:-rc\.?(\d+))?(?:-[A-Za-z0-9_.-]+)?$/;

/**
 * A final release has no ordinal. Ranking it above every candidate of its own
 * version needs no special case at each comparison if it simply holds the
 * highest possible ordinal.
 */
export const FINAL = Number.MAX_SAFE_INTEGER;

export function parseTag(name: string): Tag | null {
  const match = TAG_PATTERN.exec(name);
  if (!match) {
    return null;
  }
  const [, first, second, third, ordinal] = match;
  return {
    name,
    version: [Number(first), Number(second), Number(third ?? 0)],
    ordinal: ordinal === undefined ? FINAL : Number(ordinal),
  };
}

export function isFinal(tag: Tag): boolean {
  return tag.ordinal === FINAL;
}

/** Negative when `a` ranks below `b`, positive above, zero when equal. */
export function compare(a: Tag, b: Tag): number {
  const byVersion = compareVersions(a, b);
  return byVersion === 0 ? a.ordinal - b.ordinal : byVersion;
}

export function sameVersion(a: Tag, b: Tag): boolean {
  return a.version.every((number, index) => number === b.version[index]);
}

/** Negative when `a`'s version ranks below `b`'s, ignoring their ordinals. */
export function compareVersions(a: Tag, b: Tag): number {
  const [aFirst, aSecond, aThird] = a.version;
  const [bFirst, bSecond, bThird] = b.version;
  return aFirst - bFirst || aSecond - bSecond || aThird - bThird;
}

export function rank(tags: Tag[]): Tag[] {
  return [...tags].sort(compare);
}

/**
 * The tag a version line published, or null when it holds no tags.
 *
 * Its final when the final names the same commit as the line's last candidate,
 * otherwise that candidate. A final cut before the line's last candidate sits
 * behind it, and basing on it would re-describe everything those later
 * candidates already covered.
 *
 * The two are compared by the commit each names, not by version: a final always
 * outranks its own candidates, so ranking alone cannot tell a published boundary
 * from one cut before the version finished.
 */
export async function publishedBoundary(
  versionTags: Tag[],
  commitOf: (tag: Tag) => Promise<string | null>,
): Promise<Tag | null> {
  const ranked = rank(versionTags);
  const candidates = ranked.filter((tag) => !isFinal(tag));
  const finals = ranked.filter(isFinal);

  if (candidates.length === 0) {
    return finals.at(-1) ?? null;
  }
  if (finals.length === 0) {
    return candidates.at(-1)!;
  }

  const final = finals.at(-1)!;
  const candidate = candidates.at(-1)!;
  const finalCommit = await commitOf(final);
  if (finalCommit !== null && finalCommit === (await commitOf(candidate))) {
    return final;
  }
  return candidate;
}

/**
 * The tag the release notes should be generated from, or null for no base.
 *
 * Without a base the create step omits the boundary rather than passing an empty
 * one, which would generate notes from the entire history.
 */
export async function notesBase(
  tags: Tag[],
  pushed: Tag,
  commitOf: (tag: Tag) => Promise<string | null>,
): Promise<Tag | null> {
  const ranked = rank(tags);

  // The highest tag below the pushed tag within its own version. Each candidate
  // then documents only what changed since the last one.
  //
  // A final outranks every candidate of its version, so ranking below the pushed
  // tag already means the match is a candidate.
  const withinVersion = ranked.filter(
    (tag) => sameVersion(tag, pushed) && compare(tag, pushed) < 0,
  );
  if (withinVersion.length > 0) {
    return withinVersion.at(-1)!;
  }

  // Nothing below it in its own version, so reach back to the highest version
  // below and take that line's published boundary.
  const lower = ranked.filter((tag) => compareVersions(tag, pushed) < 0);
  if (lower.length === 0) {
    return null;
  }
  const highestLower = lower.at(-1)!;
  return publishedBoundary(
    ranked.filter((tag) => sameVersion(tag, highestLower)),
    commitOf,
  );
}

/**
 * Whether the pushed tag should be published as "Latest".
 *
 * "Latest" is publish-order by default, which is what put an older release under
 * it. A final claims it only when no final sorts above the pushed tag;
 * candidates never claim it.
 */
export function claimsLatest(tags: Tag[], pushed: Tag): boolean {
  if (!isFinal(pushed)) {
    return false;
  }
  return !tags.some((tag) => isFinal(tag) && compare(tag, pushed) > 0);
}

/**
 * Whether the tags seen so far bound the answer for `pushed`.
 *
 * The base is either in the pushed tag's own version or in the highest one
 * below it, and the listing is ordered newest-first, so a page holding a lower
 * version bounds anything a later page could contribute.
 */
export function isBounded(seen: Tag[], pushed: Tag): boolean {
  return seen.some((tag) => compareVersions(tag, pushed) < 0);
}
