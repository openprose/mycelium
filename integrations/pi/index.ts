import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

import type { ImageContent, TextContent } from "@mariozechner/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import {
	DEFAULT_MAX_BYTES,
	DEFAULT_MAX_LINES,
	formatSize,
	truncateHead,
	withFileMutationQueue,
} from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

const STATUS_KEY = "mycelium";
const STATE_ENTRY_TYPE = "mycelium-extension-state";
const TOOL_CONTEXT = "mycelium_context";
const TOOL_NOTE = "mycelium_note";
const TRACKED_TOOL_NAMES = new Set(["read", "edit", "write"]);
const MYCELIUM_TOOL_NAMES = [TOOL_CONTEXT, TOOL_NOTE] as const;
const MAX_TRACKED_PATHS = 50;
const MAX_SURFACED_FRESH_NOTES = 100;
const MAX_SURFACED_NOTE_FOLLOWUPS = 100;
const COMMAND_TIMEOUT_MS = 30_000;
const FRESH_NOTE_REMINDER_MAX_LINES = 80;
const FRESH_NOTE_REMINDER_MAX_BYTES = 8 * 1024;
const FRESH_NOTE_HEADLINE_MAX_ITEMS = 12;

export interface MyceliumPersistedState {
	version: 3;
	active: boolean;
	touchedPaths: string[];
	surfacedFreshNoteKeys: string[];
	surfacedNoteFollowupPaths: string[];
}

interface IntegrationInfo {
	workspaceRoot?: string;
	gitDir?: string;
	myceliumCommand?: string;
	contextScript?: string;
	available: boolean;
	usesJjWorkspace: boolean;
	reason?: string;
}

interface ProcessResult {
	stdout: string;
	stderr: string;
	code: number;
	killed: boolean;
}

interface ToolTextDetails {
	truncation?: unknown;
	fullOutputPath?: string;
}

const ContextParams = Type.Object({
	path: Type.Optional(Type.String({ description: "Repo-relative path to inspect. Use '.' for the project root. Default: '.'" })),
	ref: Type.Optional(Type.String({ description: "Git or jj revision to inspect. Default: HEAD." })),
	history: Type.Optional(Type.Boolean({ description: "Include historical path notes via scripts/path-history.sh. Default: false." })),
});

const NoteParams = Type.Object({
	target: Type.Optional(Type.String({ description: "Target to annotate: file path, directory path, commit ref, or HEAD (default)." })),
	kind: Type.String({ description: "Note kind, such as decision, context, summary, warning, constraint, or observation." }),
	title: Type.Optional(Type.String({ description: "Optional short title." })),
	body: Type.String({ description: "Markdown note body." }),
	slot: Type.Optional(Type.String({ description: "Optional slot name for parallel notes on the same target." })),
	status: Type.Optional(Type.String({ description: "Optional status header, such as active or archived." })),
	force: Type.Optional(Type.Boolean({ description: "Overwrite an existing note on the same target/slot." })),
	edges: Type.Optional(
		Type.Array(
			Type.Object({
				type: Type.String({ description: "Edge type, such as depends-on or warns-about." }),
				target: Type.String({ description: "Edge target, such as path:README.md or commit:abc123." }),
			}),
		),
	),
});

function createDefaultState(): MyceliumPersistedState {
	return {
		version: 3,
		active: false,
		touchedPaths: [],
		surfacedFreshNoteKeys: [],
		surfacedNoteFollowupPaths: [],
	};
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function sanitizeState(value: unknown): MyceliumPersistedState {
	if (!isRecord(value)) {
		return createDefaultState();
	}

	const active = value.active === true;
	const touchedPaths = Array.isArray(value.touchedPaths)
		? value.touchedPaths.filter((path): path is string => typeof path === "string").slice(-MAX_TRACKED_PATHS)
		: [];
	const surfacedFreshNoteKeys = Array.isArray(value.surfacedFreshNoteKeys)
		? value.surfacedFreshNoteKeys
				.filter((entry): entry is string => typeof entry === "string")
				.slice(-MAX_SURFACED_FRESH_NOTES)
		: [];
	const surfacedNoteFollowupPaths = Array.isArray(value.surfacedNoteFollowupPaths)
		? value.surfacedNoteFollowupPaths
				.filter((entry): entry is string => typeof entry === "string")
				.slice(-MAX_SURFACED_NOTE_FOLLOWUPS)
		: [];

	return {
		version: 3,
		active,
		touchedPaths,
		surfacedFreshNoteKeys,
		surfacedNoteFollowupPaths,
	};
}

export function findWorkspaceRoot(start: string): string | undefined {
	let dir = resolve(start);
	while (true) {
		if (existsSync(join(dir, ".jj")) || existsSync(join(dir, ".git"))) {
			return dir;
		}
		const parent = dirname(dir);
		if (parent === dir) {
			return undefined;
		}
		dir = parent;
	}
}

/**
 * Read the canonical mycelium SKILL.md.
 *
 * Single source of truth: the repo's root SKILL.md. This extension lives
 * at `<mycelium-repo>/integrations/pi/index.ts`, so the skill is two
 * directories up from this file. We resolve it relative to the extension's
 * own install path (via `import.meta.url`) so the skill always comes from
 * the same mycelium checkout that supplies the extension code.
 *
 * Returns file contents, or an empty string if SKILL.md is not found.
 */
export function readSkillMd(): string {
	try {
		const extensionDir = dirname(fileURLToPath(import.meta.url));
		const skillPath = resolve(extensionDir, "..", "..", "SKILL.md");
		if (existsSync(skillPath)) {
			return readFileSync(skillPath, "utf8");
		}
	} catch {
		// ignore — e.g. non-file: URL, permission error
	}
	return "";
}

export function normalizeRepoPath(inputPath: string, cwd: string, workspaceRoot: string): string | undefined {
	const resolvedPath = isAbsolute(inputPath) ? inputPath : resolve(cwd, inputPath);
	const repoRelative = relative(workspaceRoot, resolvedPath);
	if (!repoRelative) {
		return ".";
	}
	if (repoRelative === ".." || repoRelative.startsWith(`..${sep}`) || isAbsolute(repoRelative)) {
		return undefined;
	}
	return repoRelative.split(sep).join("/");
}

export function addUniqueStringValue(values: string[], nextValue: string, maxEntries = MAX_TRACKED_PATHS): string[] {
	if (values.includes(nextValue)) {
		return values;
	}
	const updated = [...values, nextValue];
	return updated.length > maxEntries ? updated.slice(updated.length - maxEntries) : updated;
}

export function addUniquePath(paths: string[], nextPath: string, maxEntries = MAX_TRACKED_PATHS): string[] {
	return addUniqueStringValue(paths, nextPath, maxEntries);
}

export function summarizePathList(paths: string[], maxItems = 5): string | undefined {
	if (paths.length === 0) {
		return undefined;
	}
	const shown = paths.slice(0, maxItems);
	return paths.length > maxItems ? `${shown.join(", ")} (+${paths.length - maxItems} more)` : shown.join(", ");
}

export function repoUsesJj(workspaceRoot: string): boolean {
	return existsSync(join(workspaceRoot, ".jj"));
}

function noteStatusIsFresh(noteText: string): boolean {
	const statusMatch = noteText.match(/^status\s+(.+)$/m);
	if (!statusMatch) {
		return true;
	}
	const status = statusMatch[1].trim().toLowerCase();
	return status !== "archived" && status !== "composted";
}

function isWorkflowContextHeader(
	line: string,
	previousLine: string | undefined,
	nextLine: string | undefined,
): boolean {
	if (!/^(?:\[exact\]|\[tree\]|\[commit\]|\[import:[^\]]+\])\s+/.test(line)) {
		return false;
	}
	if ((previousLine ?? "").trim() !== "") {
		return false;
	}
	return /^kind\s+/.test(nextLine ?? "");
}

export function extractExactContextBlocks(output: string): string[] {
	const lines = output.split(/\r?\n/);
	const blocks: string[] = [];
	let currentHeader: string | undefined;
	let currentLines: string[] = [];

	const flush = () => {
		if (!currentHeader?.startsWith("[exact]")) {
			currentHeader = undefined;
			currentLines = [];
			return;
		}
		const block = [currentHeader, ...currentLines].join("\n").trim();
		if (block && noteStatusIsFresh(block)) {
			blocks.push(block);
		}
		currentHeader = undefined;
		currentLines = [];
	};

	for (const [index, line] of lines.entries()) {
		const previousLine = index > 0 ? lines[index - 1] : undefined;
		const nextLine = index + 1 < lines.length ? lines[index + 1] : undefined;
		if (isWorkflowContextHeader(line, previousLine, nextLine)) {
			flush();
			currentHeader = line;
			continue;
		}
		if (currentHeader) {
			currentLines.push(line);
		}
	}
	flush();
	return blocks;
}

function extractExactBlockHeadline(block: string): string {
	const firstLine = block.split(/\r?\n/, 1)[0]?.trim() ?? "";
	return firstLine.replace(/^\[exact\]\s*/, "") || "(untitled)";
}

export function buildFreshNoteReminder(path: string, exactBlocks: string[]): string | undefined {
	if (exactBlocks.length === 0) {
		return undefined;
	}

	const noteLabel = exactBlocks.length === 1 ? "note is" : "notes are";
	const rawReminderLines = [
		`=== mycelium fresh exact ${exactBlocks.length === 1 ? "note" : "notes"} ===`,
		`${exactBlocks.length} fresh exact ${noteLabel} attached to the current object for ${path}.`,
	];

	if (exactBlocks.length > 1) {
		const headlines = exactBlocks.map(extractExactBlockHeadline);
		rawReminderLines.push("", "List:");
		for (const headline of headlines.slice(0, FRESH_NOTE_HEADLINE_MAX_ITEMS)) {
			rawReminderLines.push(`- ${headline}`);
		}
		if (headlines.length > FRESH_NOTE_HEADLINE_MAX_ITEMS) {
			rawReminderLines.push(`- ... (+${headlines.length - FRESH_NOTE_HEADLINE_MAX_ITEMS} more exact notes)`);
		}
	}

	rawReminderLines.push("", exactBlocks.length > 1 ? "Details:" : "Note:", "", exactBlocks.join("\n\n"), "", "Use `mycelium_context` for broader constraints, warnings, and path history.");

	const rawReminder = rawReminderLines.join("\n");
	const truncation = truncateHead(rawReminder, {
		maxLines: FRESH_NOTE_REMINDER_MAX_LINES,
		maxBytes: FRESH_NOTE_REMINDER_MAX_BYTES,
	});

	let text = truncation.content;
	if (truncation.truncated) {
		text += `\n\n[mycelium reminder truncated: showing ${truncation.outputLines} of ${truncation.totalLines} lines (${formatSize(truncation.outputBytes)} of ${formatSize(truncation.totalBytes)})]`;
	}
	return text;
}

export function buildNoteFollowupReminder(path: string): string {
	return [
		"=== mycelium note follow-up ===",
		`You changed ${path}.`,
		"Remember to update or leave mycelium notes for this touched path and for the change commit before wrap-up.",
		"Use `mycelium_note` when the relevant file, directory, or commit target is ready.",
	].join("\n");
}

function buildFreshNoteKey(path: string, reminderSource: string): string {
	return `${path}:${createHash("sha1").update(reminderSource).digest("hex")}`;
}

function appendReminderToToolContent(
	content: (TextContent | ImageContent)[],
	reminderText: string,
): (TextContent | ImageContent)[] {
	const nextContent = [...content];
	for (let i = nextContent.length - 1; i >= 0; i--) {
		const block = nextContent[i];
		if (block.type === "text") {
			nextContent[i] = {
				...block,
				text: `${block.text.trimEnd()}\n\n${reminderText}`,
			};
			return nextContent;
		}
	}
	return [...nextContent, { type: "text", text: reminderText }];
}

function getMyceliumBaseRef(integration: IntegrationInfo): string {
	const envRef = process.env.MYCELIUM_REF?.trim();
	if (envRef) {
		return envRef;
	}
	if (!integration.gitDir) {
		return "mycelium";
	}
	const branchFile = join(integration.gitDir, "mycelium-branch");
	if (existsSync(branchFile)) {
		const branchRef = readFileSync(branchFile, "utf8").trim();
		if (branchRef) {
			return branchRef;
		}
	}
	return "mycelium";
}

async function resolveContextRef(integration: IntegrationInfo, signal?: AbortSignal): Promise<string> {
	if (!integration.workspaceRoot) {
		return "HEAD";
	}
	if (integration.usesJjWorkspace) {
		const jjResult = await runCommand("jj", ["log", "-r", "@", "--no-graph", "-T", "commit_id"], {
			cwd: integration.workspaceRoot,
			signal,
			timeout: 5000,
		});
		if (jjResult.code === 0 && jjResult.stdout.trim()) {
			return jjResult.stdout.trim();
		}
	}
	return "HEAD";
}

async function collectFreshReadReminder(
	repoPath: string,
	integration: IntegrationInfo,
	signal?: AbortSignal,
): Promise<{ reminderText: string; reminderKey: string } | undefined> {
	if (!integration.available || !integration.workspaceRoot) {
		return undefined;
	}

	const env = buildCommandEnv(integration);
	if (integration.contextScript) {
		const contextRef = await resolveContextRef(integration, signal);
		const result = await runCommand(integration.contextScript, [repoPath, contextRef], {
			cwd: integration.workspaceRoot,
			env,
			signal,
			timeout: COMMAND_TIMEOUT_MS,
		});
		if (result.code !== 0) {
			return undefined;
		}
		const exactBlocks = extractExactContextBlocks(result.stdout);
		const reminderText = buildFreshNoteReminder(repoPath, exactBlocks);
		if (!reminderText) {
			return undefined;
		}
		return {
			reminderText,
			reminderKey: buildFreshNoteKey(repoPath, exactBlocks.join("\n\n")),
		};
	}

	if (!integration.myceliumCommand) {
		return undefined;
	}

	const baseRef = getMyceliumBaseRef(integration);
	const result = await runCommand(integration.myceliumCommand, ["read", repoPath], {
		cwd: integration.workspaceRoot,
		env: { ...env, MYCELIUM_REF: baseRef },
		signal,
		timeout: COMMAND_TIMEOUT_MS,
	});
	if (result.code !== 0) {
		return undefined;
	}
	const output = result.stdout.trim();
	if (!output || output.includes("(no mycelium note)") || !noteStatusIsFresh(output)) {
		return undefined;
	}
	const reminderText = buildFreshNoteReminder(repoPath, [output]);
	if (!reminderText) {
		return undefined;
	}
	return {
		reminderText,
		reminderKey: buildFreshNoteKey(repoPath, output),
	};
}

async function runCommand(
	command: string,
	args: string[],
	options: {
		cwd: string;
		env?: NodeJS.ProcessEnv;
		signal?: AbortSignal;
		timeout?: number;
	},
): Promise<ProcessResult> {
	return await new Promise((resolvePromise) => {
		let stdout = "";
		let stderr = "";
		let killed = false;
		let finished = false;
		let timeoutId: NodeJS.Timeout | undefined;

		const finish = (result: ProcessResult) => {
			if (finished) {
				return;
			}
			finished = true;
			if (timeoutId) clearTimeout(timeoutId);
			if (options.signal) options.signal.removeEventListener("abort", killProcess);
			resolvePromise(result);
		};

		const proc = spawn(command, args, {
			cwd: options.cwd,
			env: options.env,
			shell: false,
			stdio: ["ignore", "pipe", "pipe"],
		});

		const killProcess = () => {
			if (killed || finished) {
				return;
			}
			killed = true;
			proc.kill("SIGTERM");
			setTimeout(() => {
				if (!proc.killed && !finished) {
					proc.kill("SIGKILL");
				}
			}, 5000);
		};

		if (options.signal) {
			if (options.signal.aborted) {
				killProcess();
			} else {
				options.signal.addEventListener("abort", killProcess, { once: true });
			}
		}

		if (options.timeout && options.timeout > 0) {
			timeoutId = setTimeout(() => {
				killProcess();
			}, options.timeout);
		}

		proc.stdout?.on("data", (chunk) => {
			stdout += chunk.toString();
		});

		proc.stderr?.on("data", (chunk) => {
			stderr += chunk.toString();
		});

		proc.on("error", (error) => {
			finish({
				stdout,
				stderr: stderr || String(error),
				code: 1,
				killed,
			});
		});

		proc.on("close", (code) => {
			finish({
				stdout,
				stderr,
				code: code ?? 0,
				killed,
			});
		});
	});
}

async function resolveIntegration(cwd: string, signal?: AbortSignal): Promise<IntegrationInfo> {
	const workspaceRoot = findWorkspaceRoot(cwd);
	if (!workspaceRoot) {
		return {
			available: false,
			usesJjWorkspace: false,
			reason: "current cwd is not inside a git or jj workspace",
		};
	}

	const usesJjWorkspace = repoUsesJj(workspaceRoot);

	let gitDir: string | undefined;
	const repoGitDir = join(workspaceRoot, ".git");
	if (existsSync(repoGitDir)) {
		gitDir = repoGitDir;
	} else if (existsSync(join(workspaceRoot, ".jj"))) {
		const jjGitRoot = await runCommand("jj", ["git", "root"], {
			cwd: workspaceRoot,
			signal,
			timeout: 5000,
		});
		if (jjGitRoot.code === 0 && jjGitRoot.stdout.trim()) {
			gitDir = jjGitRoot.stdout.trim();
		}
	}

	const repoLocalMycelium = join(workspaceRoot, "mycelium.sh");
	let myceliumCommand: string | undefined;
	if (existsSync(repoLocalMycelium)) {
		myceliumCommand = repoLocalMycelium;
	} else {
		const commandLookup = await runCommand("bash", ["-lc", "command -v mycelium.sh"], {
			cwd: workspaceRoot,
			signal,
			timeout: 5000,
		});
		if (commandLookup.code === 0 && commandLookup.stdout.trim()) {
			myceliumCommand = commandLookup.stdout.trim().split(/\r?\n/, 1)[0];
		}
	}

	const contextScriptPath = join(workspaceRoot, "scripts", "context-workflow.sh");
	const contextScript = existsSync(contextScriptPath) ? contextScriptPath : undefined;
	const available = Boolean(myceliumCommand && gitDir);

	let reason: string | undefined;
	if (!myceliumCommand) {
		reason = "mycelium.sh not found in repo root or PATH";
	} else if (!gitDir) {
		reason = "could not resolve the git directory for this workspace";
	}

	return {
		workspaceRoot,
		gitDir,
		myceliumCommand,
		contextScript,
		available,
		usesJjWorkspace,
		reason,
	};
}

function buildCommandEnv(integration: IntegrationInfo): NodeJS.ProcessEnv {
	if (!integration.workspaceRoot || !integration.gitDir) {
		return { ...process.env };
	}
	return {
		...process.env,
		GIT_DIR: integration.gitDir,
		GIT_WORK_TREE: integration.workspaceRoot,
	};
}

function applyToolActivation(pi: ExtensionAPI, state: MyceliumPersistedState, integration: IntegrationInfo | undefined) {
	const currentTools = new Set(pi.getActiveTools());
	for (const toolName of MYCELIUM_TOOL_NAMES) {
		currentTools.delete(toolName);
	}
	if (state.active && integration?.available) {
		for (const toolName of MYCELIUM_TOOL_NAMES) {
			currentTools.add(toolName);
		}
	}
	pi.setActiveTools(Array.from(currentTools));
}

function updateStatus(ctx: ExtensionContext, state: MyceliumPersistedState, integration: IntegrationInfo | undefined) {
	if (!integration?.workspaceRoot) {
		ctx.ui.setStatus(STATUS_KEY, "mycelium unavailable");
		return;
	}
	const mode = integration.available ? (state.active ? "mycelium on" : "mycelium off") : "mycelium unavailable";
	const touchedSuffix = state.touchedPaths.length > 0 ? ` · ${state.touchedPaths.length} touched` : "";
	ctx.ui.setStatus(STATUS_KEY, `${mode}${touchedSuffix}`);
}

function restoreStateFromBranch(ctx: ExtensionContext): MyceliumPersistedState {
	let state = createDefaultState();
	for (const entry of ctx.sessionManager.getBranch()) {
		if (entry.type === "custom" && entry.customType === STATE_ENTRY_TYPE) {
			state = sanitizeState(entry.data);
		}
	}
	return state;
}

function recordTouchedPath(
	state: MyceliumPersistedState,
	ctx: ExtensionContext,
	integration: IntegrationInfo | undefined,
	event: { toolName: string; input: Record<string, unknown>; isError: boolean },
): MyceliumPersistedState {
	if (event.isError || !TRACKED_TOOL_NAMES.has(event.toolName) || !integration?.workspaceRoot) {
		return state;
	}
	const inputPath = event.input.path;
	if (typeof inputPath !== "string") {
		return state;
	}
	const normalizedPath = normalizeRepoPath(inputPath, ctx.cwd, integration.workspaceRoot);
	if (!normalizedPath) {
		return state;
	}
	const touchedPaths = addUniquePath(state.touchedPaths, normalizedPath);
	if (touchedPaths === state.touchedPaths) {
		return state;
	}
	return { ...state, touchedPaths };
}

function recordSurfacedFreshNote(state: MyceliumPersistedState, reminderKey: string): MyceliumPersistedState {
	const surfacedFreshNoteKeys = addUniqueStringValue(
		state.surfacedFreshNoteKeys,
		reminderKey,
		MAX_SURFACED_FRESH_NOTES,
	);
	if (surfacedFreshNoteKeys === state.surfacedFreshNoteKeys) {
		return state;
	}
	return { ...state, surfacedFreshNoteKeys };
}

function recordSurfacedNoteFollowup(state: MyceliumPersistedState, path: string): MyceliumPersistedState {
	const surfacedNoteFollowupPaths = addUniqueStringValue(
		state.surfacedNoteFollowupPaths,
		path,
		MAX_SURFACED_NOTE_FOLLOWUPS,
	);
	if (surfacedNoteFollowupPaths === state.surfacedNoteFollowupPaths) {
		return state;
	}
	return { ...state, surfacedNoteFollowupPaths };
}

function persistStateIfChanged(
	pi: ExtensionAPI,
	currentState: MyceliumPersistedState,
	nextState: MyceliumPersistedState,
): MyceliumPersistedState {
	if (nextState === currentState) {
		return currentState;
	}
	pi.appendEntry<MyceliumPersistedState>(STATE_ENTRY_TYPE, nextState);
	return nextState;
}

function formatProcessSection(title: string, command: string, result: ProcessResult): string {
	const lines = [`=== ${title} ===`, `$ ${command}`];
	const stdout = result.stdout.trimEnd();
	const stderr = result.stderr.trimEnd();
	if (stdout) {
		lines.push(stdout);
	}
	if (stderr) {
		lines.push("[stderr]");
		lines.push(stderr);
	}
	if (!stdout && !stderr) {
		lines.push("(no output)");
	}
	if (result.code !== 0) {
		lines.push(`[exit ${result.code}${result.killed ? ", terminated" : ""}]`);
	}
	return lines.join("\n");
}

async function formatToolTextResult(text: string, details: Record<string, unknown>): Promise<{
	content: [{ type: "text"; text: string }];
	details: Record<string, unknown> & ToolTextDetails;
}> {
	const truncation = truncateHead(text, {
		maxLines: DEFAULT_MAX_LINES,
		maxBytes: DEFAULT_MAX_BYTES,
	});

	let finalText = truncation.content;
	const finalDetails: Record<string, unknown> & ToolTextDetails = { ...details };
	if (truncation.truncated) {
		const tempDir = await mkdtemp(join(tmpdir(), "mycelium-pi-"));
		const fullOutputPath = join(tempDir, "output.txt");
		await withFileMutationQueue(fullOutputPath, async () => {
			await writeFile(fullOutputPath, text, "utf8");
		});

		finalDetails.truncation = truncation;
		finalDetails.fullOutputPath = fullOutputPath;

		const omittedLines = truncation.totalLines - truncation.outputLines;
		const omittedBytes = truncation.totalBytes - truncation.outputBytes;
		finalText += `\n\n[Output truncated: showing ${truncation.outputLines} of ${truncation.totalLines} lines`;
		finalText += ` (${formatSize(truncation.outputBytes)} of ${formatSize(truncation.totalBytes)}).`;
		finalText += ` ${omittedLines} lines (${formatSize(omittedBytes)}) omitted.`;
		finalText += ` Full output saved to: ${fullOutputPath}]`;
	}

	return {
		content: [{ type: "text", text: finalText }],
		details: finalDetails,
	};
}

function buildPromptReminder(state: MyceliumPersistedState): string {
	const touched = summarizePathList(state.touchedPaths, 5);
	const lines = [
		"## Mycelium",
		"This repo uses mycelium notes.",
		"- Prefer `mycelium_context` and `mycelium_note` inside Pi; use raw `mycelium.sh` from bash only for commands the extension does not expose yet, or when debugging raw note behavior.",
		"- Use `mycelium_context` before editing unfamiliar areas so you see repo constraints, warnings, and path-specific context.",
		"- Fresh exact file notes may appear automatically after successful `read` tool calls when this extension is active.",
		"- Successful `edit` and `write` tool calls may append hidden note follow-up reminders when this extension is active.",
		"- After meaningful work, leave concise mycelium notes on touched files or directories and on the change commit with `mycelium_note`.",
	];
	if (touched) {
		lines.push(`- Touched paths so far in this branch/session: ${touched}.`);
	}
	return lines.join("\n");
}

function buildStatusMessage(state: MyceliumPersistedState, integration: IntegrationInfo | undefined): string {
	const lines = [
		`active: ${state.active && integration?.available ? "yes" : "no"}`,
		`workspace root: ${integration?.workspaceRoot ?? "(not found)"}`,
		`git dir: ${integration?.gitDir ?? "(not resolved)"}`,
		`mycelium command: ${integration?.myceliumCommand ?? "(not found)"}`,
		`context workflow: ${integration?.contextScript ?? "(fallback mode only)"}`,
		`jj workspace: ${integration?.usesJjWorkspace ? "yes" : "no"}`,
		`tracked touched paths: ${summarizePathList(state.touchedPaths, 8) ?? "(none yet)"}`,
		`surfaced fresh note reminders: ${state.surfacedFreshNoteKeys.length}`,
		`surfaced note follow-up reminders: ${state.surfacedNoteFollowupPaths.length}`,
	];
	if (!integration?.available && integration?.reason) {
		lines.push(`availability: ${integration.reason}`);
	}
	lines.push("commands: /mycelium status | /mycelium on | /mycelium off | /mycelium reset");
	return lines.join("\n");
}

export default function myceliumExtension(pi: ExtensionAPI) {
	let state = createDefaultState();
	let integration: IntegrationInfo | undefined;
	// Tracks whether SKILL.md has been injected during the current activation
	// cycle. Resets whenever state.active goes false → true, so turning
	// mycelium off then on again re-injects the skill.
	let skillInjectedThisCycle = false;

	const persistState = () => {
		pi.appendEntry<MyceliumPersistedState>(STATE_ENTRY_TYPE, state);
	};

	const syncState = (ctx: ExtensionContext) => {
		applyToolActivation(pi, state, integration);
		updateStatus(ctx, state, integration);
	};

	pi.registerCommand("mycelium", {
		description: "Mycelium controls: status, on, off, reset, help",
		handler: async (args, ctx) => {
			const subcommand = args.trim().split(/\s+/, 1)[0]?.toLowerCase() || "status";
			if (subcommand === "help") {
				ctx.ui.notify(buildStatusMessage(state, integration), "info");
				return;
			}
			if (subcommand === "status") {
				ctx.ui.notify(buildStatusMessage(state, integration), "info");
				return;
			}
			if (subcommand === "reset") {
				state = { ...state, touchedPaths: [], surfacedFreshNoteKeys: [], surfacedNoteFollowupPaths: [] };
				persistState();
				syncState(ctx);
				ctx.ui.notify("mycelium touched-path, fresh-note, and note-follow-up reminder history reset", "info");
				return;
			}
			if (subcommand === "on" || subcommand === "activate") {
				if (!integration?.available) {
					ctx.ui.notify(`mycelium is unavailable: ${integration?.reason ?? "missing integration prerequisites"}`, "warning");
					return;
				}
				// Transition from off → on resets the skill injection flag,
				// so the next agent turn dumps SKILL.md into context.
				if (!state.active) {
					skillInjectedThisCycle = false;
				}
				state = { ...state, active: true };
				persistState();
				syncState(ctx);
				ctx.ui.notify("mycelium activated: tools enabled for this branch/session", "info");
				return;
			}
			if (subcommand === "off" || subcommand === "deactivate") {
				state = { ...state, active: false };
				skillInjectedThisCycle = false;
				persistState();
				syncState(ctx);
				ctx.ui.notify("mycelium deactivated: tools removed from the active set", "info");
				return;
			}
			ctx.ui.notify("Usage: /mycelium [status|on|off|reset|help]", "warning");
		},
	});

	pi.registerTool({
		name: TOOL_CONTEXT,
		label: "Mycelium Context",
		description: `Inspect mycelium repo context for a path. Runs mycelium constraint and warning discovery plus the repo's context workflow. Output is truncated to ${DEFAULT_MAX_LINES} lines or ${formatSize(DEFAULT_MAX_BYTES)}.` ,
		promptSnippet: "Inspect mycelium constraints, warnings, and path context before editing unfamiliar areas",
		promptGuidelines: [
			"Use this before editing unfamiliar files in a mycelium-enabled repo or when the user asks for repo context.",
		],
		parameters: ContextParams,
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			if (!integration?.available || !integration.myceliumCommand || !integration.workspaceRoot) {
				throw new Error(`mycelium integration is unavailable: ${integration?.reason ?? "missing repo metadata"}`);
			}

			const env = buildCommandEnv(integration);
			const inspectPath = params.path?.trim() || ".";
			const inspectRef = params.ref?.trim();
			const effectiveRef = inspectRef ?? (integration.usesJjWorkspace ? await resolveContextRef(integration, signal) : undefined);
			const sections: string[] = [];

			for (const kind of ["constraint", "warning"] as const) {
				const result = await runCommand(integration.myceliumCommand, ["find", kind], {
					cwd: ctx.cwd,
					env,
					signal,
					timeout: COMMAND_TIMEOUT_MS,
				});
				sections.push(formatProcessSection(`mycelium ${kind}s`, `${integration.myceliumCommand} find ${kind}`, result));
			}

			if (integration.contextScript) {
				const contextArgs = [inspectPath];
				if (effectiveRef) {
					contextArgs.push(effectiveRef);
				}
				if (params.history) {
					contextArgs.push("--history");
				}
				const result = await runCommand(integration.contextScript, contextArgs, {
					cwd: ctx.cwd,
					env,
					signal,
					timeout: COMMAND_TIMEOUT_MS,
				});
				sections.push(
					formatProcessSection(
						"workflow context",
						`${integration.contextScript} ${contextArgs.join(" ")}`,
						result,
					),
				);
			} else {
				const result = await runCommand(integration.myceliumCommand, ["read", inspectPath], {
					cwd: ctx.cwd,
					env,
					signal,
					timeout: COMMAND_TIMEOUT_MS,
				});
				sections.push(
					[
						"=== workflow context fallback ===",
						"scripts/context-workflow.sh is not available in this repo; falling back to `mycelium.sh read`.",
						formatProcessSection("path note", `${integration.myceliumCommand} read ${inspectPath}`, result),
					].join("\n"),
				);
			}

			return await formatToolTextResult(sections.join("\n\n"), {
				path: inspectPath,
				ref: effectiveRef ?? "HEAD",
				history: params.history === true,
				workspaceRoot: integration.workspaceRoot,
			});
		},
	});

	pi.registerTool({
		name: TOOL_NOTE,
		label: "Mycelium Note",
		description: "Write a structured mycelium note on a file, directory, commit, or HEAD.",
		promptSnippet: "Write mycelium notes on files, directories, or commits",
		promptGuidelines: [
			"Use this after meaningful work to leave concise agent-facing context on touched files or directories and on the change commit.",
		],
		parameters: NoteParams,
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			if (!integration?.available || !integration.myceliumCommand) {
				throw new Error(`mycelium integration is unavailable: ${integration?.reason ?? "missing repo metadata"}`);
			}

			const env = buildCommandEnv(integration);
			const args = ["note"];
			if (params.target?.trim()) {
				args.push(params.target.trim());
			}
			args.push("-k", params.kind, "-m", params.body);
			if (params.title?.trim()) {
				args.push("-t", params.title.trim());
			}
			if (params.slot?.trim()) {
				args.push("--slot", params.slot.trim());
			}
			if (params.status?.trim()) {
				args.push("-s", params.status.trim());
			}
			if (params.force) {
				args.push("-f");
			}
			for (const edge of params.edges ?? []) {
				args.push("-e", edge.type, edge.target);
			}

			const result = await runCommand(integration.myceliumCommand, args, {
				cwd: ctx.cwd,
				env,
				signal,
				timeout: COMMAND_TIMEOUT_MS,
			});
			if (result.code !== 0) {
				const message = result.stderr.trim() || result.stdout.trim() || `mycelium note failed with exit code ${result.code}`;
				throw new Error(message);
			}

			const target = params.target?.trim() || "HEAD";
			const summary = result.stdout.trim() || `Wrote mycelium note on ${target}`;
			return {
				content: [{ type: "text", text: summary }],
				details: {
					target,
					kind: params.kind,
					title: params.title,
					slot: params.slot,
					status: params.status,
				},
			};
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		integration = await resolveIntegration(ctx.cwd, ctx.signal);
		state = restoreStateFromBranch(ctx);
		syncState(ctx);
	});

	pi.on("session_tree", async (_event, ctx) => {
		state = restoreStateFromBranch(ctx);
		syncState(ctx);
	});

	pi.on("tool_result", async (event, ctx) => {
		let nextState = recordTouchedPath(state, ctx, integration, {
			toolName: event.toolName,
			input: event.input,
			isError: event.isError,
		});
		let nextContent = event.content;

		if (state.active && integration?.available && !event.isError && integration.workspaceRoot) {
			const inputPath = event.input.path;
			if (typeof inputPath === "string") {
				const normalizedPath = normalizeRepoPath(inputPath, ctx.cwd, integration.workspaceRoot);
				if (normalizedPath && normalizedPath !== ".") {
					if (event.toolName === "read") {
						const reminder = await collectFreshReadReminder(normalizedPath, integration, ctx.signal);
						if (reminder && !nextState.surfacedFreshNoteKeys.includes(reminder.reminderKey)) {
							nextContent = appendReminderToToolContent(nextContent, reminder.reminderText);
							nextState = recordSurfacedFreshNote(nextState, reminder.reminderKey);
						}
					}
					if ((event.toolName === "edit" || event.toolName === "write") && !nextState.surfacedNoteFollowupPaths.includes(normalizedPath)) {
						nextContent = appendReminderToToolContent(nextContent, buildNoteFollowupReminder(normalizedPath));
						nextState = recordSurfacedNoteFollowup(nextState, normalizedPath);
					}
				}
			}
		}

		state = persistStateIfChanged(pi, state, nextState);
		updateStatus(ctx, state, integration);
		if (nextContent !== event.content) {
			return { content: nextContent };
		}
	});

	pi.on("before_agent_start", async (event) => {
		if (!state.active || !integration?.available) {
			return;
		}
		// On the first turn after activation, dump SKILL.md into context
		// so the agent learns the mycelium protocol. Subsequent turns only
		// get the short reminder — the skill stays in the system prompt
		// via the platform's prompt caching.
		let additions = buildPromptReminder(state);
		if (!skillInjectedThisCycle) {
			const skillContent = readSkillMd();
			if (skillContent) {
				additions = `${skillContent}\n\n${additions}`;
			}
			skillInjectedThisCycle = true;
		}
		return {
			systemPrompt: `${event.systemPrompt}\n\n${additions}`,
		};
	});
}
