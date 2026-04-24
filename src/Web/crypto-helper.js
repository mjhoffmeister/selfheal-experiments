'use strict';

const crypto = require('crypto');

const ALGO = 'aes-192-cbc';
const KEY_LEN = 24; // aes-192 requires a 24-byte key
const IV_LEN = 16;  // AES CBC requires a 16-byte IV
const SALT = 'selfheal-experiments-static-salt';

// Derive a deterministic key and IV from the passphrase using scrypt.
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
  return signToken(payload, passphrase) === token;
}

module.exports = { signToken, verifyToken };