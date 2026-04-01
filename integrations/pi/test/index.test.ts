import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  addUniquePath,
  buildFreshNoteReminder,
  buildNoteFollowupReminder,
  extractExactContextBlocks,
  findWorkspaceRoot,
  normalizeRepoPath,
  summarizePathList,
} from "../index.ts";

const tempDirs: string[] = [];

async function makeTempDir() {
  const dir = await mkdtemp(join(tmpdir(), "mycelium-pi-test-"));
  tempDirs.push(dir);
  return dir;
}

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("findWorkspaceRoot", () => {
  test("finds a git root from a nested directory", async () => {
    const root = await makeTempDir();
    await mkdir(join(root, ".git"));
    await mkdir(join(root, "src", "nested"), { recursive: true });

    expect(findWorkspaceRoot(join(root, "src", "nested"))).toBe(root);
  });

  test("finds a jj workspace root from a nested directory", async () => {
    const root = await makeTempDir();
    await mkdir(join(root, ".jj"));
    await mkdir(join(root, "a", "b"), { recursive: true });

    expect(findWorkspaceRoot(join(root, "a", "b"))).toBe(root);
  });
});

describe("normalizeRepoPath", () => {
  test("normalizes a relative path within the repo", async () => {
    const root = await makeTempDir();
    await mkdir(join(root, "src"), { recursive: true });
    await writeFile(join(root, "src", "file.ts"), "ok\n");

    expect(normalizeRepoPath("src/file.ts", root, root)).toBe("src/file.ts");
  });

  test("returns dot for the repo root", async () => {
    const root = await makeTempDir();
    expect(normalizeRepoPath(root, root, root)).toBe(".");
  });

  test("rejects paths outside the repo root", async () => {
    const root = await makeTempDir();
    const outside = await makeTempDir();

    expect(normalizeRepoPath(outside, root, root)).toBeUndefined();
  });
});

describe("path helpers", () => {
  test("dedupes while preserving insertion order", () => {
    expect(addUniquePath(["a.ts", "b.ts"], "b.ts")).toEqual(["a.ts", "b.ts"]);
    expect(addUniquePath(["a.ts", "b.ts"], "c.ts")).toEqual(["a.ts", "b.ts", "c.ts"]);
  });

  test("summarizes long lists", () => {
    expect(summarizePathList(["a", "b", "c"], 2)).toBe("a, b (+1 more)");
    expect(summarizePathList([], 2)).toBeUndefined();
  });
});

describe("fresh note helpers", () => {
  test("extracts only fresh exact blocks from workflow output", () => {
    const output = [
      "=== workflow context: integrations/pi/index.ts @ abc (mycelium) ===",
      "",
      "[exact] Active note (summary)",
      "kind summary",
      "edge applies-to blob:abc",
      "",
      "Useful details.",
      "",
      "[tree] Parent dir note (context)",
      "kind context",
      "",
      "[exact] Archived note (warning)",
      "kind warning",
      "status archived",
      "",
      "Old details.",
      "",
      "[commit] Commit note (context)",
      "kind context",
    ].join("\n");

    expect(extractExactContextBlocks(output)).toEqual([
      [
        "[exact] Active note (summary)",
        "kind summary",
        "edge applies-to blob:abc",
        "",
        "Useful details.",
      ].join("\n"),
    ]);
  });

  test("builds multi-note reminders with a list before details", () => {
    const reminder = buildFreshNoteReminder("integrations/pi/index.ts", [
      ["[exact] First note (summary)", "kind summary", "", "First details."].join("\n"),
      ["[exact] [slot:dogfood] Second note (warning)", "kind warning", "", "Second details."].join("\n"),
    ]);

    expect(reminder).toContain("=== mycelium fresh exact notes ===");
    expect(reminder).toContain("2 fresh exact notes are attached to the current object for integrations/pi/index.ts.");
    expect(reminder).toContain("List:");
    expect(reminder).toContain("- First note (summary)");
    expect(reminder).toContain("- [slot:dogfood] Second note (warning)");
    expect(reminder).toContain("Details:");
    expect(reminder).toContain("First details.");
    expect(reminder).toContain("Second details.");
  });

  test("builds note follow-up reminders for edited paths", () => {
    const reminder = buildNoteFollowupReminder("integrations/pi/index.ts");

    expect(reminder).toContain("=== mycelium note follow-up ===");
    expect(reminder).toContain("You changed integrations/pi/index.ts.");
    expect(reminder).toContain("Remember to update or leave mycelium notes for this touched path and for the change commit before wrap-up.");
    expect(reminder).toContain("Use `mycelium_note` when the relevant file, directory, or commit target is ready.");
  });
});
