'use strict';

// Sign an opaque session token.
//
// Replaced the removed crypto.createCipher (hard-removed in Node 22) with
// crypto.createCipheriv. A 24-byte key and 16-byte IV are both derived
// deterministically from the passphrase via scryptSync so that
// signToken(payload, passphrase) always returns the same value for the same
// inputs — matching the contract relied on by verifyToken.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';
// Static salts are intentional: the helper must be deterministic so that
// verifyToken can re-derive the same ciphertext and compare. This trades
// salt randomness for predictability — acceptable for a token-verification
// scheme where the "salt" is effectively baked into the deployment secret.
const SCRYPT_SALT_KEY = 'crypto-helper-key';
const SCRYPT_SALT_IV  = 'crypto-helper-iv';

function deriveKeyAndIv(passphrase) {
  const key = crypto.scryptSync(passphrase, SCRYPT_SALT_KEY, 24);
  const iv  = crypto.scryptSync(passphrase, SCRYPT_SALT_IV,  16);
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
  return signToken(payload, passphrase) === token;
}

module.exports = { signToken, verifyToken };
