'use strict';

// Sign an opaque session token using HMAC-SHA256.
//
// HMAC is the appropriate primitive for token signing: it is deterministic
// for the same payload/passphrase pair, does not require an IV or a separate
// key-derivation step, and is designed for authentication rather than
// encryption.
const crypto = require('crypto');

function signToken(payload, passphrase) {
  return crypto.createHmac('sha256', passphrase)
    .update(payload)
    .digest('hex');
}

function verifyToken(token, payload, passphrase) {
  const expected = signToken(payload, passphrase);
  return token.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(token, 'hex'), Buffer.from(expected, 'hex'));
}

module.exports = { signToken, verifyToken };
