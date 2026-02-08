import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
// Versioning: uncomment when creating a new version.
// import { docsVersionsLoader } from 'starlight-versions/loader';

export const collections = {
	docs: defineCollection({ loader: docsLoader(), schema: docsSchema() }),
	// Versioning: uncomment when creating a new version.
	// versions: defineCollection({ loader: docsVersionsLoader() }),
};
