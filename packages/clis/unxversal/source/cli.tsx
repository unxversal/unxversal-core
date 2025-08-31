#!/usr/bin/env node
import React from 'react';
import {render} from 'ink';
import meow from 'meow';
import App from './app.js';
import Settings from './settings.js';
import {SyntheticsIndexer} from './synthetics/indexer.js';
import {LendingIndexer} from './lending/indexer.js';
import {LendingKeeper} from './lending/keeper.js';
import {loadConfig} from './lib/config.js';
import { startServer } from './server.js';

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
	(async () => {
		// start HTTP server for data/UI integrations
		const srv = await startServer();
		(globalThis as any).__unxv_server = srv;
		// auto-start synthetics indexer
		try {
			const cfg = await loadConfig();
			if (cfg?.synthetics?.packageId) {
				const sx = await SyntheticsIndexer.fromConfig();
				await sx.init();
				(globalThis as any).__unxv_indexer = sx;
				const sinceMs = cfg.indexer.backfillSinceMs ?? Date.now();
				const types = cfg.indexer.types;
				void sx.backfillThenFollow(cfg.synthetics.packageId!, sinceMs, types, cfg.indexer.windowDays);
			}
			// auto-start lending indexer
			if (cfg?.lending?.packageId) {
				const lx = await LendingIndexer.fromConfig();
				await lx.init();
				(globalThis as any).__unxv_lending_indexer = lx;
				const sinceMs = cfg.indexer.backfillSinceMs ?? Date.now();
				void lx.backfillThenFollow(cfg.lending.packageId!, sinceMs);
			}
			// auto-start lending keeper (rates/accrual)
			if (cfg?.lending?.packageId) {
				const lk = await LendingKeeper.fromConfig();
				lk.start(15000);
				(globalThis as any).__unxv_lending_keeper = lk;
			}
		} catch {}
		render(<App name={cli.flags.name} />);
	})();
}
