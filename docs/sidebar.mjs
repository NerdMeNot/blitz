/** Shared sidebar config — used by astro.config.mjs and scripts/snapshot.mjs */
export default [
	{ label: 'Introduction', slug: 'index' },
	{
		label: 'Getting Started',
		items: [
			{ label: 'Installation', slug: 'getting-started/installation' },
			{ label: 'Quick Start', slug: 'getting-started/quick-start' },
			{ label: 'Basic Concepts', slug: 'getting-started/basic-concepts' },
		],
	},
	{
		label: 'Usage',
		items: [
			{ label: 'Iterators', slug: 'usage/iterators' },
			{ label: 'Fork-Join', slug: 'usage/fork-join' },
			{ label: 'Sorting', slug: 'usage/sorting' },
			{ label: 'Initialization', slug: 'usage/initialization' },
			{ label: 'Parallel For', slug: 'usage/parallel-for' },
			{ label: 'Parallel Reduce', slug: 'usage/parallel-reduce' },
			{ label: 'Scope & Broadcast', slug: 'usage/scope-broadcast' },
			{ label: 'Collect & Scatter', slug: 'usage/collect-scatter' },
			{ label: 'Error Handling', slug: 'usage/error-handling' },
		],
	},
	{
		label: 'Cookbook',
		items: [
			{ label: 'Overview', slug: 'cookbook' },
			{ label: 'Image Processing', slug: 'cookbook/image-processing' },
			{ label: 'CSV Parsing', slug: 'cookbook/csv-parsing' },
			{ label: 'Monte Carlo Simulation', slug: 'cookbook/monte-carlo' },
			{ label: 'Log File Analysis', slug: 'cookbook/log-analysis' },
			{ label: 'Matrix Multiplication', slug: 'cookbook/matrix-multiplication' },
			{ label: 'Parallel File Scanning', slug: 'cookbook/file-scanning' },
			{ label: 'Numerical Integration', slug: 'cookbook/numerical-integration' },
			{ label: 'Game Physics', slug: 'cookbook/game-physics' },
			{ label: 'Data Normalization', slug: 'cookbook/data-normalization' },
			{ label: 'Search Index', slug: 'cookbook/search-index' },
		],
	},
	{
		label: 'Guides',
		items: [
			{ label: 'Performance Tuning', slug: 'guides/performance-tuning' },
			{ label: 'Migration from Sequential', slug: 'guides/migration' },
			{ label: 'Choosing the Right API', slug: 'guides/choosing-api' },
		],
	},
	{
		label: 'API Reference',
		items: [
			{ label: 'Core API', slug: 'api/core-api' },
			{ label: 'Iterators API', slug: 'api/iterators-api' },
			{ label: 'Sort API', slug: 'api/sort-api' },
			{ label: 'Internal API', slug: 'api/internal-api' },
			{
				label: 'Zig Autodocs',
				link: '/api-reference/',
				attrs: { target: '_blank' },
			},
		],
	},
	{
		label: 'Algorithms',
		items: [
			{ label: 'Work Stealing', slug: 'algorithms/work-stealing' },
			{ label: 'Chase-Lev Deque', slug: 'algorithms/chase-lev-deque' },
			{ label: 'PDQSort', slug: 'algorithms/pdqsort' },
			{ label: 'Parallel Reduction', slug: 'algorithms/parallel-reduction' },
			{ label: 'Adaptive Splitting', slug: 'algorithms/adaptive-splitting' },
			{ label: 'Early Exit Operations', slug: 'algorithms/early-exit-operations' },
		],
	},
	{
		label: 'Testing',
		items: [
			{ label: 'Running Tests', slug: 'testing/running-tests' },
			{ label: 'Benchmarking', slug: 'testing/benchmarking' },
			{ label: 'Comparing with Rayon', slug: 'testing/comparing-with-rayon' },
		],
	},
	{
		label: 'Internals',
		items: [
			{ label: 'Architecture', slug: 'internals/architecture' },
			{ label: 'Thread Pool', slug: 'internals/thread-pool' },
			{ label: 'Futures and Jobs', slug: 'internals/futures-and-jobs' },
			{ label: 'Synchronization', slug: 'internals/synchronization' },
			{ label: 'Sleep-Wake Protocol', slug: 'internals/sleep-wake-protocol' },
		],
	},
];
