import { logger } from './utils/logger.js';
import { version } from './config.js';

async function main(): Promise<void> {
  logger.info();
  logger.info('Scripts entrypoint ready.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
