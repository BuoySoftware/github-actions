/**
 * Tests the release-identity ranking.
 *
 * Release identity is easy to get wrong in ways that look green. Notes generated
 * from the wrong base silently describe the wrong range of commits, often
 * hundreds of them. A final release that declines "Latest" leaves consumers
 * pointing at an older version, and a candidate that claims it misdirects
 * everyone.
 *
 * Ranking is a pure function of the tag list, so it is called directly. Tag lists
 * are given in an order that is deliberately not version order, matching the API:
 * a function that trusts the order it receives fails here.
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  claimsLatest,
  compare,
  isBounded,
  isFinal,
  notesBase,
  parseTag,
  publishedBoundary,
  rank,
  type Tag,
} from "../src/identity.js";

function tags(...names: string[]): Tag[] {
  return rank(names.map(parseTag).filter((tag): tag is Tag => tag !== null));
}

function parsed(name: string): Tag {
  const tag = parseTag(name);
  if (!tag) {
    throw new Error(`${name} should parse as a version tag`);
  }
  return tag;
}

/** Each tag on its own commit, as they are unless deliberately co-located. */
const distinctCommits = async (tag: Tag) => `sha-${tag.name}`;

async function baseOf(pushed: string, ...names: string[]): Promise<string | null> {
  const base = await notesBase(tags(...names), parsed(pushed), distinctCommits);
  return base?.name ?? null;
}

function latestOf(pushed: string, ...names: string[]): boolean {
  return claimsLatest(tags(...names), parsed(pushed));
}

describe("parseTag", () => {
  it("accepts two- and three-part versions", () => {
    assert.deepEqual(parsed("v3.0").version, [3, 0, 0]);
    assert.deepEqual(parsed("v2.2.1").version, [2, 2, 1]);
  });

  it("counts an absent third number as zero", () => {
    // `v2.2` and `v2.2.0` name one version, so a repository writing both shapes
    // does not get two release lines out of them.
    assert.deepEqual(parsed("v2.2").version, parsed("v2.2.0").version);
  });

  it("accepts dotted and dotless ordinals", () => {
    assert.equal(parsed("v1.0-rc.4").ordinal, 4);
    assert.equal(parsed("v1.0-rc4").ordinal, 4);
  });

  it("treats a tag with no ordinal as final", () => {
    assert.ok(isFinal(parsed("v1.0")));
    assert.ok(!isFinal(parsed("v1.0-rc.1")));
  });

  it("gives suffixes no ordering information", () => {
    assert.equal(compare(parsed("v36.0-rc.6-mega"), parsed("v36.0-rc.6")), 0);
  });

  it("does not read a suffix that merely contains rc as an ordinal", () => {
    assert.ok(isFinal(parsed("v1.0-rcsomething")));
  });

  it("requires the leading v", () => {
    // The retired `YYYYMMDD.N` scheme parses as versions with a leading number in
    // the millions, which would outrank every real release forever.
    assert.equal(parseTag("20240131.1"), null);
    assert.equal(parseTag("35.3"), null);
  });

  it("rejects tags that are not versions", () => {
    for (const name of ["latest", "v1", "v1.x", "release-1.0", "v1.0.0.0"]) {
      assert.equal(parseTag(name), null, name);
    }
  });

  it("ranks a final above every candidate of its version", () => {
    for (const ordinal of ["1", "9", "999999"]) {
      assert.ok(compare(parsed("v1.0"), parsed(`v1.0-rc.${ordinal}`)) > 0);
    }
  });

  it("ranks numbers left to right", () => {
    const ordered = ["v2.2.0", "v2.2.1", "v2.3.0", "v3.0.0", "v10.0.0", "v100.0.0"];
    assert.deepEqual(
      tags(...[...ordered].reverse()).map((tag) => tag.name),
      ordered,
    );
  });
});

describe("notesBase", () => {
  // Mirrors the shapes the real repositories carry: two- and three-part versions,
  // dotted and dotless ordinals, trailing suffixes, and a sparse gap where a
  // minor was never cut.
  const MAIN = [
    "v35.3",
    "v36.0-rc.1",
    "v36.0-rc.6-mega",
    "v36.0-rc.7-mega",
    "v36.0",
    "v36.1",
    "v37.0-rc.1",
    "v37.0-rc.3",
    "v37.0-rc.4",
  ];

  it("bases a candidate on the one below it", async () => {
    assert.equal(await baseOf("v37.0-rc.4", ...MAIN), "v37.0-rc.3");
  });

  it("bases a final on its own last candidate", async () => {
    assert.equal(await baseOf("v36.0", ...MAIN), "v36.0-rc.7-mega");
  });

  it("reaches back when a version has no candidate below the pushed tag", async () => {
    assert.equal(await baseOf("v37.0-rc.1", ...MAIN), "v36.1");
  });

  it("never bases on a final of its own version", async () => {
    assert.equal(await baseOf("v36.0-rc.7-mega", ...MAIN), "v36.0-rc.6-mega");
  });

  it("bases a final on its last candidate rather than itself", async () => {
    assert.equal(await baseOf("v2.0", "v2.0-rc.1", "v2.0", "v1.0"), "v2.0-rc.1");
  });

  it("reaches past a final that sits behind its line's last candidate", async () => {
    assert.equal(await baseOf("v36.1", ...MAIN), "v36.0-rc.7-mega");
  });

  it("ignores versions above the pushed tag", async () => {
    assert.equal(await baseOf("v36.0-rc.1", "v36.0-rc.1", "v37.0", "v35.3"), "v35.3");
  });

  it("crosses a gap where a version was never cut", async () => {
    assert.equal(await baseOf("v36.0-rc.1", ...MAIN), "v35.3");
  });

  it("gives no base when nothing is below", async () => {
    // The create call then omits the boundary rather than passing an empty one,
    // which would generate notes from the entire history.
    assert.equal(await baseOf("v1.0", "v1.0", "v2.0"), null);
  });

  it("never bases on a tag that is not a version", async () => {
    assert.equal(await baseOf("v2.0", "latest", "nightly", "20240131.1"), null);
  });

  it("treats every version tag as a candidate base", async () => {
    // Excluding test and personal tags would make the base depend on who cut the
    // surrounding ones.
    assert.equal(
      await baseOf("v2.1", "v2.0-rc.1", "v2.0-rc.2-someone_test"),
      "v2.0-rc.2-someone_test",
    );
  });
});

describe("publishedBoundary", () => {
  async function boundary(
    names: string[],
    commits: Record<string, string | null> = {},
  ): Promise<string | null> {
    const found = await publishedBoundary(tags(...names), async (tag) =>
      tag.name in commits ? commits[tag.name]! : `sha-${tag.name}`,
    );
    return found?.name ?? null;
  }

  it("prefers the final when it names the last candidate's commit", async () => {
    assert.equal(
      await boundary(["v2.1.0-rc.1", "v2.1.0"], {
        "v2.1.0": "shared",
        "v2.1.0-rc.1": "shared",
      }),
      "v2.1.0",
    );
  });

  it("prefers the last candidate when the final sits behind it", async () => {
    assert.equal(
      await boundary(["v2.1.0-rc.1", "v2.1.0", "v2.1.0-rc.2"]),
      "v2.1.0-rc.2",
    );
  });

  it("falls back to the candidate when the final names no commit", async () => {
    // A partial fetch can leave a tag object that names no commit. Guessing the
    // final is the boundary would silently widen the notes.
    assert.equal(
      await boundary(["v2.1.0-rc.1", "v2.1.0"], { "v2.1.0": null }),
      "v2.1.0-rc.1",
    );
  });

  it("takes the final from a line with no candidates", async () => {
    assert.equal(await boundary(["v2.1.0"]), "v2.1.0");
  });

  it("takes the last candidate from a line with no final", async () => {
    assert.equal(await boundary(["v2.1.0-rc.1", "v2.1.0-rc.2"]), "v2.1.0-rc.2");
  });

  it("gives no boundary from an empty line", async () => {
    assert.equal(await boundary([]), null);
  });
});

describe("claimsLatest", () => {
  it("lets a final with nothing above it claim latest", () => {
    assert.ok(latestOf("v3.0", "v2.0", "v3.0"));
  });

  it("declines for a final below another final", () => {
    // "Latest" defaults to publish order, which is what put an older release
    // under it. Re-cutting an old tag must not move the pointer back.
    assert.ok(!latestOf("v2.0", "v2.0", "v3.0"));
  });

  it("never lets a candidate claim latest", () => {
    assert.ok(!latestOf("v9.0-rc.1", "v1.0", "v9.0-rc.1"));
  });

  it("does not let candidates above a final block its claim", () => {
    // Ranking above the pushed tag is not enough to block the claim, only a
    // higher final is. The candidates are of the version directly above, so each
    // outranks the pushed final outright.
    assert.ok(latestOf("v36.0", "v36.0", "v36.1-rc.1", "v36.1-rc.2"));
  });

  it("does not let a candidate of the pushed version block it", () => {
    assert.ok(latestOf("v36.0", "v36.0-rc.1", "v36.0"));
  });

  it("lets a suffixed final block a lower final's claim", () => {
    assert.ok(!latestOf("v2.0", "v2.0", "v3.0-pltf"));
  });

  it("does not let the retired scheme block a claim", () => {
    assert.ok(latestOf("v3.0", "v3.0", "20240131.1", "20991231.9"));
  });

  it("lets the first release claim latest", () => {
    assert.ok(latestOf("v1.0", "v1.0"));
  });
});

describe("isBounded", () => {
  it("is bounded once a lower version has been seen", () => {
    assert.ok(isBounded(tags("v9.0", "v8.0"), parsed("v9.0")));
  });

  it("is not bounded by candidates of the pushed version", () => {
    assert.ok(!isBounded(tags("v9.0-rc.1", "v9.0-rc.2"), parsed("v9.0")));
  });

  it("is not bounded by versions above the pushed tag", () => {
    assert.ok(!isBounded(tags("v10.0", "v11.0"), parsed("v9.0")));
  });

  it("is not bounded by an empty listing", () => {
    assert.ok(!isBounded([], parsed("v9.0")));
  });
});
