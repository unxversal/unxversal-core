import { logger } from './utils/logger.js';
import { sleep } from './utils/time.js';

/** Example cron task that runs indefinitely */
async function runCron(): Promise<void> {
  logger.info('Cron started');
  // TODO: replace with real cron jobs (e.g., rebalancing, upkeep)
  for (;;) {
    logger.info('Cron heartbeat');
    await sleep(60_000);
  }
}

runCron().catch((err) => {
  console.error(err);
  process.exit(1);
});
