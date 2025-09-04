import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const pkg = require('../package.json');
export const version = pkg.version as string;
export const env = {
  NODE_ENV: process.env.NODE_ENV ?? 'development',
};
