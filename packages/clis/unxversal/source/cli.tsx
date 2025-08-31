#!/usr/bin/env node
import React from 'react';
import {render} from 'ink';
import meow from 'meow';
import App from './app.js';
import Settings from './settings.js';
import {SyntheticsIndexer} from './synthetics/indexer.js';
import {loadConfig} from './lib/config.js';

const cli = meow(
	`
	Usage
	  $ unxversal

	Options
		--name       Your name
		--settings   Open settings UI
		--start-indexer  Start synthetics indexer (backfill then follow)

	Examples
	  $ unxversal --name=Jane
	  Hello, Jane
`,
	{
		importMeta: import.meta,
		flags: {
			name: { type: 'string' },
			settings: { type: 'boolean', default: false },
			startIndexer: { type: 'boolean', default: false },
		},
	},
);


if (cli.flags.startIndexer) {
	(async () => {
		const cfg = await loadConfig();
		if (!cfg?.synthetics.packageId) {
			console.error('Missing synthetics.packageId in settings.');
			process.exit(1);
		}
		const indexer = await SyntheticsIndexer.fromConfig();
		await indexer.init();
		;(globalThis as any).__unxv_indexer = indexer;
		const sinceMs = cfg.indexer.backfillSinceMs ?? Date.now();
		const types = cfg.indexer.types;
		process.on('SIGINT', () => { indexer.stop(); process.exit(0); });
		process.on('SIGTERM', () => { indexer.stop(); process.exit(0); });
		await indexer.backfillThenFollow(cfg.synthetics.packageId!, sinceMs, types, cfg.indexer.windowDays);
	})();
} else if (cli.flags.settings) {
	render(<Settings />);
} else {
	render(<App name={cli.flags.name} />);
}
