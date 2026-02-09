#!/usr/bin/env node
/**
 * Create a version snapshot of the current docs.
 *
 * Usage:
 *   bun scripts/snapshot.mjs v1.0.0-zig0.15.2
 *
 * This copies all doc content (excluding version subdirs) to a versioned
 * directory and writes the sidebar JSON that starlight-versions expects.
 */
import { cpSync, mkdirSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import sidebar from '../sidebar.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const docsRoot = resolve(__dirname, '..');
const contentDocsDir = resolve(docsRoot, 'src/content/docs');
const versionsDir = resolve(docsRoot, 'src/content/versions');

const tag = process.argv[2];
if (!tag) {
	console.error('Usage: bun scripts/snapshot.mjs <tag>');
	process.exit(1);
}

const snapshotDir = resolve(contentDocsDir, tag);
const versionJson = resolve(versionsDir, `${tag}.json`);

if (existsSync(snapshotDir)) {
	console.log(`Snapshot ${tag} already exists at ${snapshotDir}, skipping`);
	process.exit(0);
}

// Copy all doc files, excluding version subdirectories
console.log(`Creating snapshot: ${tag}`);
mkdirSync(snapshotDir, { recursive: true });

const entries = readdirSync(contentDocsDir);
for (const entry of entries) {
	const srcPath = join(contentDocsDir, entry);
	const stat = statSync(srcPath);

	// Skip version snapshot directories (they contain dots like "v1.0.0-zig0.15.2")
	if (stat.isDirectory() && entry.includes('.')) continue;

	cpSync(srcPath, join(snapshotDir, entry), { recursive: true });
}

// Write version metadata (sidebar config)
mkdirSync(versionsDir, { recursive: true });
writeFileSync(versionJson, JSON.stringify({ sidebar }, null, 2) + '\n');

console.log(`Snapshot created: ${snapshotDir}`);
console.log(`Version config: ${versionJson}`);
