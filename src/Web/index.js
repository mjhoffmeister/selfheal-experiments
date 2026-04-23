'use strict';

const express = require('express');
const pino = require('pino');

require('dotenv').config();

const log = pino({ level: process.env.LOG_LEVEL || 'info' });

function createApp() {
  const app = express();
  app.get('/health', (_req, res) => res.json({ status: 'ok' }));
  app.get('/greet/:name', (req, res) => {
    res.json({ message: `hello, ${req.params.name}` });
  });
  return app;
}

if (require.main === module) {
  const port = Number(process.env.PORT || 3000);
  createApp().listen(port, () => log.info({ port }, 'listening'));
}

module.exports = { createApp };
