# @unxversal/scripts

A TypeScript workspace for operational scripts: deployments, admin tasks, and background cron jobs.

## Commands

- `npm run dev`: Run the main entry in watch mode (tsx).
- `npm run build`: Compile TypeScript to `dist`.
- `npm start`: Run compiled main entry.
- `npm run cron`: Run the background cron loop (compiled).
- `npm run deploy:example`: Run an example deploy script (compiled).

## Structure

- `src/index.ts`: Main entry / dispatcher.
- `src/cron.ts`: Background cron loop.
- `src/deploy/`\: Deployment scripts live here.
- `src/utils/`\: Shared utilities (logger, time, etc.).

## Development

- Use Node 18+.
- Add new scripts under `src/deploy` and expose a `run()` function.
- Build before running `start`, `cron`, or `deploy:*` commands.

## Notes

This package is private and intended for internal operational use within the monorepo.
