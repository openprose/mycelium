import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { addUniquePath, findWorkspaceRoot, normalizeRepoPath, summarizePathList } from "../index.ts";

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
