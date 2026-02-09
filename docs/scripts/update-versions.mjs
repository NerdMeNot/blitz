#!/usr/bin/env node
/**
 * Manage versions.json.
 *
 * Usage:
 *   bun scripts/update-versions.mjs add <tag>          Add a new release
 *   bun scripts/update-versions.mjs set-latest <tag>   Mark an existing version as latest
 *   bun scripts/update-versions.mjs list               Show current config
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const configPath = resolve(__dirname, '..', 'versions.json');

const [action, tag] = process.argv.slice(2);

if (!action || !['add', 'set-latest', 'list'].includes(action)) {
	console.error('Usage:');
	console.error('  bun scripts/update-versions.mjs add <tag>');
	console.error('  bun scripts/update-versions.mjs set-latest <tag>');
	console.error('  bun scripts/update-versions.mjs list');
	process.exit(1);
}

let config;
try {
	config = JSON.parse(readFileSync(configPath, 'utf-8'));
} catch {
	config = { current: null, history: [] };
}

if (action === 'list') {
	console.log(`current: ${config.current || '(none)'}`);
	if (config.history.length > 0) {
		console.log(`history: ${config.history.join(', ')}`);
	} else {
		console.log('history: (none)');
	}
	process.exit(0);
}

if (!tag) {
	console.error(`Error: <tag> is required for '${action}'`);
	process.exit(1);
}

if (action === 'add') {
	// Move previous current to history
	if (config.current && config.current !== tag && !config.history.includes(config.current)) {
		config.history.unshift(config.current);
	}
	config.current = tag;
}

if (action === 'set-latest') {
	// Remove tag from history if it's there
	config.history = config.history.filter(v => v !== tag);
	// Move old current to history
	if (config.current && config.current !== tag && !config.history.includes(config.current)) {
		config.history.unshift(config.current);
	}
	config.current = tag;
}

writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
console.log(`versions.json: current=${config.current}, history=[${config.history.join(', ')}]`);
