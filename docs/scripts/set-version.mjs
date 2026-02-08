#!/usr/bin/env node
/**
 * Enable/disable starlight-versions in the docs config.
 *
 * Usage:
 *   node scripts/set-version.mjs enable v1.0.0-zig0.15.2
 *   node scripts/set-version.mjs disable
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const docsRoot = resolve(__dirname, '..');

const [action, tag] = process.argv.slice(2);

if (action === 'enable') {
	if (!tag) {
		console.error('Error: TAG is required. Usage: node scripts/set-version.mjs enable <tag>');
		process.exit(1);
	}
	enableVersioning(tag);
} else if (action === 'disable') {
	disableVersioning();
} else {
	console.error('Usage: node scripts/set-version.mjs <enable|disable> [tag]');
	process.exit(1);
}

function enableVersioning(tag) {
	// astro.config.mjs
	const configPath = resolve(docsRoot, 'astro.config.mjs');
	let config = readFileSync(configPath, 'utf-8');

	config = config.replace(
		/\/\/ Versioning: uncomment when creating a new version\.\n\/\/ import starlightVersions from 'starlight-versions';/,
		"import starlightVersions from 'starlight-versions';"
	);
	config = config.replace(
		/\/\/ Versioning: uncomment when a new version differs from the v[\w.-]+ snapshot\.\n\t\t\t\/\/ plugins: \[\n\t\t\t\/\/ \tstarlightVersions\(\{\n\t\t\t\/\/ \t\tversions: \[.*\],\n\t\t\t\/\/ \t\}\),\n\t\t\t\/\/ \],/,
		`plugins: [\n\t\t\t\tstarlightVersions({\n\t\t\t\t\tversions: [{ slug: '${tag}', label: '${tag}' }],\n\t\t\t\t}),\n\t\t\t],`
	);

	writeFileSync(configPath, config);
	console.log(`astro.config.mjs: versioning enabled (${tag})`);

	// content.config.ts
	const contentPath = resolve(docsRoot, 'src/content.config.ts');
	let content = readFileSync(contentPath, 'utf-8');

	content = content.replace(
		/\/\/ Versioning: uncomment when creating a new version\.\n\/\/ import \{ docsVersionsLoader \}/,
		"import { docsVersionsLoader }"
	);
	content = content.replace(
		/\t\/\/ Versioning: uncomment when creating a new version\.\n\t\/\/ versions: defineCollection/,
		"\tversions: defineCollection"
	);

	writeFileSync(contentPath, content);
	console.log('content.config.ts: versioning enabled');
}

function disableVersioning() {
	// astro.config.mjs
	const configPath = resolve(docsRoot, 'astro.config.mjs');
	let config = readFileSync(configPath, 'utf-8');

	config = config.replace(
		/^import starlightVersions from 'starlight-versions';$/m,
		"// Versioning: uncomment when creating a new version.\n// import starlightVersions from 'starlight-versions';"
	);
	config = config.replace(
		/\t\t\tplugins: \[\n\t\t\t\tstarlightVersions\(\{\n\t\t\t\t\tversions: \[\{ slug: '([^']+)', label: '[^']+' \}\],\n\t\t\t\t\}\),\n\t\t\t\],/,
		`\t\t\t// Versioning: uncomment when a new version differs from the v$1 snapshot.\n\t\t\t// plugins: [\n\t\t\t// \tstarlightVersions({\n\t\t\t// \t\tversions: [{ slug: '$1', label: '$1' }],\n\t\t\t// \t}),\n\t\t\t// ],`
	);

	writeFileSync(configPath, config);
	console.log('astro.config.mjs: versioning disabled');

	// content.config.ts
	const contentPath = resolve(docsRoot, 'src/content.config.ts');
	let content = readFileSync(contentPath, 'utf-8');

	content = content.replace(
		/^import \{ docsVersionsLoader \}/m,
		"// Versioning: uncomment when creating a new version.\n// import { docsVersionsLoader }"
	);
	content = content.replace(
		/^\tversions: defineCollection/m,
		"\t// Versioning: uncomment when creating a new version.\n\t// versions: defineCollection"
	);

	writeFileSync(contentPath, content);
	console.log('content.config.ts: versioning disabled');
}
