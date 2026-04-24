'use strict';

// Sign an opaque session token. Ported from the Node < 22 implementation that
// used crypto.createCipher, which was hard-removed in Node 22.
//
// The key and IV are derived from the passphrase using OpenSSL's
// EVP_BytesToKey (MD5, 1 iteration, no salt) so that tokens produced here
// are identical to those produced by the previous implementation.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';
const KEY_LEN = 24; // aes-192 key: 192 bits
const IV_LEN = 16;  // aes-192-cbc IV: 128 bits

// Replicates OpenSSL EVP_BytesToKey(md5, 1 iteration, no salt).
// crypto.createCipher used this derivation internally before Node 22 removed it.
function evpBytesToKey(passphrase) {
  const pass = Buffer.from(passphrase, 'binary');
  const needed = KEY_LEN + IV_LEN;
  const blocks = [];
  let prev = Buffer.alloc(0);
  while (blocks.reduce((sum, b) => sum + b.length, 0) < needed) {
    prev = crypto.createHash('md5').update(prev).update(pass).digest();
    blocks.push(prev);
  }
  const material = Buffer.concat(blocks);
  return { key: material.subarray(0, KEY_LEN), iv: material.subarray(KEY_LEN, KEY_LEN + IV_LEN) };
}

function signToken(payload, passphrase) {
  const { key, iv } = evpBytesToKey(passphrase);
  const cipher = crypto.createCipheriv(ALGO, key, iv);
  let out = cipher.update(payload, 'utf8', 'hex');
  out += cipher.final('hex');
  return out;
}

function verifyToken(token, payload, passphrase) {
  return signToken(payload, passphrase) === token;
}

module.exports = { signToken, verifyToken };
