// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import tailwindcss from '@tailwindcss/vite';
import starlightVersions from 'starlight-versions';
import { readFileSync } from 'node:fs';
import sidebar from './sidebar.mjs';

// Read version config
let versionsConfig;
try {
	versionsConfig = JSON.parse(readFileSync(new URL('./versions.json', import.meta.url), 'utf-8'));
} catch {
	versionsConfig = { current: null, history: [] };
}

// Only enable version plugin when there are older versions to show
const versionPlugins = versionsConfig.history.length > 0
	? [starlightVersions({
			current: { label: `${versionsConfig.current} (Latest)` },
			versions: versionsConfig.history.map(v => ({ slug: v, label: v })),
		})]
	: [];

// https://astro.build/config
export default defineConfig({
	site: 'https://blitz.nerdmenot.in',
	vite: {
		plugins: [tailwindcss()],
	},
	integrations: [
		starlight({
			title: 'Blitz',
			logo: {
				light: './public/logo-light.png',
				dark: './public/logo-dark.png',
				replacesTitle: true,
			},
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/NerdMeNot/blitz' },
			],
			plugins: versionPlugins,
			components: {
				ThemeSelect: './src/components/ThemeSelect.astro',
				Head: './src/components/Head.astro',
			},
			customCss: [
				'./src/styles/global.css',
			],
			sidebar,
		}),
	],
});
