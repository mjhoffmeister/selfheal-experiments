'use strict';

// Sign an opaque session token. Implementation predates Node 22.
//
// Note: crypto.createCipher was a legacy API that derived a key from the
// passphrase via OpenSSL's EVP_BytesToKey. It was removed in Node 22.
// Replaced with createCipheriv + scryptSync-derived key and IV so that
// the output remains deterministic for the same passphrase (required by
// existing callers and tests) while using a supported API.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';
const KEY_LEN = 24; // AES-192 key size in bytes
const IV_LEN = 16;  // AES block size / CBC IV size in bytes

function deriveKeyAndIv(passphrase) {
  const key = crypto.scryptSync(passphrase, 'sign-key', KEY_LEN);
  const iv  = crypto.scryptSync(passphrase, 'sign-iv',  IV_LEN);
  return { key, iv };
}

function signToken(payload, passphrase) {
  const { key, iv } = deriveKeyAndIv(passphrase);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  let out = cipher.update(payload, 'utf8', 'hex');
  out += cipher.final('hex');
  return out;
}

function verifyToken(token, payload, passphrase) {
  try {
    const expected = signToken(payload, passphrase);
    return crypto.timingSafeEqual(Buffer.from(token), Buffer.from(expected));
  } catch {
    return false;
  }
}

module.exports = { signToken, verifyToken };
