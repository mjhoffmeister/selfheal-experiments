'use strict';

// Sign an opaque session token. Implementation predates Node 22.
//
// Note: crypto.createCipher is a legacy API. It derives a key from the
// passphrase via OpenSSL's EVP_BytesToKey, which is not considered secure
// for new code. Kept here for backward-compatibility with tokens issued by
// the previous version of this service.
const crypto = require('crypto');

const ALGO = 'aes-192-cbc';

function signToken(payload, passphrase) {
  const cipher = crypto.createCipher(ALGO, passphrase);
  let out = cipher.update(payload, 'utf8', 'hex');
  out += cipher.final('hex');
  return out;
}

function verifyToken(token, payload, passphrase) {
  return signToken(payload, passphrase) === token;
}

module.exports = { signToken, verifyToken };