'use strict';

const request = require('supertest');
const { createApp } = require('./index');

describe('web fixture', () => {
  const app = createApp();

  test('GET /health returns ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });

  test('GET /greet/:name echoes the name', async () => {
    const res = await request(app).get('/greet/world');
    expect(res.status).toBe(200);
    expect(res.body.message).toBe('hello, world');
  });
});
