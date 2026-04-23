'use strict';

// Sign an opaque session token.
//
// Uses crypto.createCipheriv with a key and IV derived from the passphrase
// via scrypt (RFC 7914). The salt is fixed so that signToken is deterministic
// for the same payload+passphrase pair, which is required for verifyToken.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';
const KEY_LEN = 24; // bytes — AES-192 key size
const IV_LEN = 16;  // bytes — AES block size
const SALT = Buffer.alloc(16, 0); // fixed salt keeps output deterministic

function deriveKeyAndIv(passphrase) {
  const derived = crypto.scryptSync(passphrase, SALT, KEY_LEN + IV_LEN);
  return { key: derived.subarray(0, KEY_LEN), iv: derived.subarray(KEY_LEN) };
}

function signToken(payload, passphrase) {
  const { key, iv } = deriveKeyAndIv(passphrase);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  let out = cipher.update(payload, 'utf8', 'hex');
  out += cipher.final('hex');
  return out;
}

function verifyToken(token, payload, passphrase) {
  const expected = signToken(payload, passphrase);
  if (token.length !== expected.length) return false;
  return crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected));
}

module.exports = { signToken, verifyToken };
