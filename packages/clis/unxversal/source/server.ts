import express from 'express';
import {Pool} from 'pg';
import {loadConfig} from './lib/config.js';
import { coreRouter } from './server/routes/core.js';
import { synthRouter } from './server/routes/synthetics.js';
import { lendingRouter } from './server/routes/lending.js';
import { indexerRouter } from './server/routes/indexer.js';
import { botsRouter } from './server/routes/bots.js';
import { synthOrdersVaultsRouter } from './server/routes/synthetics-orders-vaults.js';
import { oraclesRouter } from './server/routes/oracles.js';
import swaggerUi from 'swagger-ui-express';
import swaggerJSDoc from 'swagger-jsdoc';

export async function startServer(port?: number) {
  const cfg = await loadConfig();
  const app = express();
  app.use(express.json());
  const pool = new Pool({ connectionString: cfg?.postgresUrl });

  // Mount routers
  app.use(coreRouter(pool));
  app.use('/synthetics', synthRouter(pool));
  app.use('/lending', lendingRouter(pool));
  app.use(indexerRouter(pool));
  app.use(botsRouter(pool));
  app.use(synthOrdersVaultsRouter(pool));
  app.use(oraclesRouter(pool));

  // Swagger setup
  const swaggerSpec = swaggerJSDoc({
    definition: {
      openapi: '3.0.0',
      info: { title: 'Unxversal CLI API', version: '1.0.0' },
    },
    apis: [],
  });
  app.use('/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec));

  const server = app.listen(port || 0);
  const addr = server.address();
  const boundPort = typeof addr === 'object' && addr ? addr.port : (port || 0);
  return { port: boundPort, close: () => server.close() };
}


