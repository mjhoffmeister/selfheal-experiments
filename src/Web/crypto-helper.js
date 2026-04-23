'use strict';

// Sign an opaque session token.
//
// Uses crypto.createCipheriv with a key derived from the passphrase via
// scrypt (fixed salt) and a fixed IV, so the output is deterministic for the
// same payload + passphrase pair. crypto.createCipher was hard-removed in
// Node 22 (deprecated since Node 10); this is the modern replacement.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';
const KEY_LEN = 24; // 192 bits
const IV_LEN = 16;  // AES block size
const SALT = 'selfheal-fixed-salt';
const FIXED_IV = Buffer.alloc(IV_LEN, 0);

function deriveKey(passphrase) {
  return crypto.scryptSync(passphrase, SALT, KEY_LEN);
}

function signToken(payload, passphrase) {
  const key = deriveKey(passphrase);
  const cipher = crypto.createCipheriv(ALGO, key, FIXED_IV);
  let out = cipher.update(payload, 'utf8', 'hex');
  out += cipher.final('hex');
  return out;
}

function verifyToken(token, payload, passphrase) {
  return signToken(payload, passphrase) === token;
}

module.exports = { signToken, verifyToken };
