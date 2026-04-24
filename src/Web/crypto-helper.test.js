'use strict';

const { signToken, verifyToken } = require('./crypto-helper');

describe('crypto-helper', () => {
  test('signToken is deterministic for the same passphrase', () => {
    const a = signToken('user-42', 'shared-secret');
    const b = signToken('user-42', 'shared-secret');
    expect(a).toBe(b);
  });

  test('verifyToken accepts a freshly signed token', () => {
    const token = signToken('user-42', 'shared-secret');
    expect(verifyToken(token, 'user-42', 'shared-secret')).toBe(true);
  });

  test('verifyToken rejects a token signed with a different passphrase', () => {
    const token = signToken('user-42', 'shared-secret');
    expect(verifyToken(token, 'user-42', 'wrong-secret')).toBe(false);
  });

  test('verifyToken rejects a token for a different payload', () => {
    const token = signToken('user-42', 'shared-secret');
    expect(verifyToken(token, 'user-99', 'shared-secret')).toBe(false);
  });
});
