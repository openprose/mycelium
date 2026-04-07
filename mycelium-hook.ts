/**
 * Mycelium hook for Pi — auto-injects git notes context.
 *
 * Contract (see PLUGIN-SPEC.md):
 * - before_agent_start: inject SKILL.md + constraints + warnings + doctor + note count
 * - tool_result (read): inject per-file notes from all refs/slots
 * - tool_result (write/edit): track mutations
 * - agent_end: nudge with file list if mutations occurred
 *
 * Install: symlink or copy to ~/.pi/agent/extensions/mycelium.ts
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve, relative, isAbsolute } from "node:path";

const MYCELIUM_SH_LOCATIONS = [
  resolve(process.env.HOME ?? "", ".agents/skills/mycelium/mycelium.sh"),
  resolve(process.env.HOME ?? "", ".local/bin/mycelium.sh"),
];

function findMyceliumSh(): string | null {
  for (const loc of MYCELIUM_SH_LOCATIONS) {
    if (existsSync(loc)) return loc;
  }
  return null;
}

const SKILL_MD_LOCATIONS = [
  // Repo root is checked dynamically with cwd
  resolve(process.env.HOME ?? "", ".agents/skills/mycelium/SKILL.md"),
];

function findSkillMd(cwd: string): string | null {
  const repoRoot = run("git rev-parse --show-toplevel", cwd);
  if (repoRoot) {
    const repoSkill = resolve(repoRoot, "SKILL.md");
    if (existsSync(repoSkill)) return repoSkill;
  }
  for (const loc of SKILL_MD_LOCATIONS) {
    if (existsSync(loc)) return loc;
  }
  return null;
}

function run(cmd: string, cwd: string): string {
  try {
    return execSync(cmd, { cwd, timeout: 5000, encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

function isGitRepo(cwd: string): boolean {
  return run("git rev-parse --is-inside-work-tree", cwd) === "true";
}

function hasMyceliumNotes(cwd: string): boolean {
  return run("git notes --ref=mycelium list", cwd) !== "";
}

export default function (pi: ExtensionAPI) {
  const mutatedFiles = new Set<string>();
  let stopHookActive = false;

  // Session start: inject SKILL.md + constraints + warnings + doctor + note count
  pi.on("before_agent_start", async (event, ctx) => {
    mutatedFiles.clear();
    stopHookActive = false;

    if (!isGitRepo(ctx.cwd)) return;
    if (!hasMyceliumNotes(ctx.cwd)) return;

    const parts: string[] = [];

    // SKILL.md
    const skillPath = findSkillMd(ctx.cwd);
    if (skillPath) {
      try {
        const skillContent = readFileSync(skillPath, "utf8");
        parts.push(skillContent);
      } catch { /* skip */ }
    }

    const script = findMyceliumSh();

    // Constraints
    if (script) {
      const constraints = run(`bash "${script}" find constraint`, ctx.cwd);
      if (constraints) parts.push(`## Constraint notes\n${constraints}`);
    }

    // Warnings
    if (script) {
      const warnings = run(`bash "${script}" find warning`, ctx.cwd);
      if (warnings) parts.push(`## Warning notes\n${warnings}`);
    }

    // Doctor
    if (script) {
      const doctor = run(`bash "${script}" doctor`, ctx.cwd);
      if (doctor) parts.push(`## Graph state\n${doctor}`);
    }

    // Note count
    const noteCount = run("git notes --ref=mycelium list | wc -l", ctx.cwd);
    if (noteCount) parts.push(`Note count: ${noteCount}`);

    if (parts.length === 0) return;

    return {
      message: {
        customType: "mycelium-context",
        content: `[mycelium] Context for this repo:\n\n${parts.join("\n\n")}`,
        display: false,
      },
    };
  });

  // tool_result: inject per-file notes on read, track mutations on write/edit
  pi.on("tool_result", async (event, ctx) => {
    // Track file mutations
    if (event.toolName === "write" || event.toolName === "edit") {
      const path = event.input?.path;
      if (path && !event.isError) {
        mutatedFiles.add(path);
      }
      return;
    }

    // Per-file note injection on read
    if (event.toolName === "read") {
      const filePath = event.input?.file_path || event.input?.path;
      if (!filePath) return;
      if (!isGitRepo(ctx.cwd)) return;

      // Convert to repo-relative path
      const repoRoot = run("git rev-parse --show-toplevel", ctx.cwd);
      if (!repoRoot) return;

      let relPath: string;
      if (isAbsolute(filePath)) {
        relPath = relative(repoRoot, filePath);
      } else {
        relPath = relative(repoRoot, resolve(ctx.cwd, filePath));
      }

      // Skip paths outside repo
      if (relPath.startsWith("..")) return;

      // Get blob OID for current HEAD
      const oid = run(`git rev-parse HEAD:${relPath}`, ctx.cwd);
      if (!oid) return;

      const noteParts: string[] = [];

      // Check default ref
      const defaultNote = run(`git notes --ref=mycelium show ${oid}`, ctx.cwd);
      if (defaultNote) noteParts.push(`[mycelium] ${relPath}:\n${defaultNote}`);

      // Check slot refs
      const slotRefs = run(
        "git for-each-ref --format='%(refname:short)' refs/notes/mycelium--slot--*",
        ctx.cwd
      );
      if (slotRefs) {
        for (const ref of slotRefs.split("\n")) {
          if (!ref) continue;
          const slotNote = run(`git notes --ref="${ref}" show ${oid}`, ctx.cwd);
          if (slotNote) {
            const slotName = ref.replace(/^.*mycelium--slot--/, "");
            noteParts.push(`[mycelium slot:${slotName}] ${relPath}:\n${slotNote}`);
          }
        }
      }

      if (noteParts.length === 0) return;

      return {
        message: {
          customType: "mycelium-file-note",
          content: noteParts.join("\n\n"),
          display: false,
        },
      };
    }
  });

  // After agent finishes, nudge with file list if files were changed
  pi.on("agent_end", async (_event, ctx) => {
    if (stopHookActive) return;
    if (mutatedFiles.size === 0) return;
    if (!isGitRepo(ctx.cwd)) return;
    if (!hasMyceliumNotes(ctx.cwd)) return;

    stopHookActive = true;

    const files = [...mutatedFiles];
    mutatedFiles.clear();

    const fileList = files.map((f) => `  - ${f}`).join("\n");
    const nudge =
      `📡 ${files.length} file(s) changed — consider leaving mycelium notes:\n` +
      `${fileList}\n\n` +
      `Use: mycelium.sh note <file> -k <kind> -m "<what future agents should know>"`;

    ctx.ui.setStatus("mycelium", nudge);
  });
}
