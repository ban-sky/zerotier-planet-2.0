/*
  ztncui - ZeroTier network controller UI
  Copyright (C) 2017-2021  Key Networks (https://key-networks.com)
  Licensed under GPLv3 - see LICENSE for details.
*/

const express = require('express');
const auth = require('../controllers/auth');
const authenticate = auth.authenticate;
const restrict = auth.restrict;
const router = express.Router();
const usersController = require('../controllers/usersController');

// Live runtime statistics for the overview cards. The privileged collector
// writes the file; this endpoint only reads it, and only for signed-in users.
const runtimeStats = require('./stats');

router.get('/stats.json', restrict, function(req, res) {
  res.set('Cache-Control', 'no-store');
  res.json(runtimeStats.summarise(runtimeStats.read()));
});

// Translate a user-visible string when the i18n middleware is installed; fall
// back to the key so the UI still renders when it is not.
function msg(req, key, vars) {
  return req.t ? req.t(key, vars) : key;
}

// Failed-login throttling: 10 failures per account and source address in a
// 15 minute window. The bucket is keyed by address *and* username on purpose.
// Behind a reverse proxy without TRUST_PROXY every request looks like it comes
// from 127.0.0.1; keying on the address alone would let a single attacker lock
// every administrator out of the panel. Per-address totals are still capped so
// one source cannot spray guesses across many account names.
const MAX_FAILURES = 10;
const MAX_FAILURES_PER_ADDRESS = 50;
const FAILURE_WINDOW_MS = 15 * 60 * 1000;
const MAX_TRACKED_KEYS = 5000;
const failures = new Map();

function clientIp(req) {
  return req.ip || (req.socket && req.socket.remoteAddress) || 'unknown';
}

function attemptKey(req, scope, name) {
  const account = typeof name === 'string' ? name.trim().toLowerCase().slice(0, 64) : '';
  return clientIp(req) + '|' + scope + '|' + account;
}

function failureRecord(key) {
  const now = Date.now();
  let record = failures.get(key);
  if (!record || record.reset <= now) {
    if (failures.size >= MAX_TRACKED_KEYS) failures.clear();
    record = { count: 0, reset: now + FAILURE_WINDOW_MS };
    failures.set(key, record);
  }
  return record;
}

function addressFailures(req) {
  const prefix = clientIp(req) + '|';
  const now = Date.now();
  let total = 0;
  for (const [key, record] of failures) {
    if (key.indexOf(prefix) === 0 && record.reset > now) total += record.count;
  }
  return total;
}

function isThrottled(req, scope, name) {
  if (addressFailures(req) >= MAX_FAILURES_PER_ADDRESS) return true;
  const record = failures.get(attemptKey(req, scope, name));
  return !!record && record.reset > Date.now() && record.count >= MAX_FAILURES;
}

function recordFailure(req, scope, name) {
  const record = failureRecord(attemptKey(req, scope, name));
  record.count += 1;
}

function clearFailures(req, scope, name) {
  failures.delete(attemptKey(req, scope, name));
}

const cleanup = setInterval(() => {
  const now = Date.now();
  for (const [key, record] of failures) {
    if (record.reset <= now) failures.delete(key);
  }
}, 5 * 60 * 1000);
if (cleanup.unref) cleanup.unref();

/** Only allow redirects to a local absolute path. */
function safeRedirect(target) {
  if (typeof target !== 'string' || target.length === 0 || target.length > 512) {
    return '/controller';
  }
  if (target[0] !== '/' || target[1] === '/' || target[1] === '\\') {
    return '/controller';
  }
  return target;
}

/** Redirect logged user to controller page */
function guest_only(req, res, next) {
  if (req.session.user) {
    res.redirect('/controller');
  } else {
    next();
  }
}

/* GET home page. */
router.get('/', guest_only, function(req, res, next) {
  res.render('front_door', { title: 'ztncui' });
});

router.get('/logout', function(req, res) {
  req.session.destroy(function() {
    res.clearCookie('ztncui.sid', { path: '/' });
    res.redirect('/');
  });
});

router.get('/login', guest_only, function(req, res) {
  let message = null;
  if (req.session.error) {
    if (req.session.error !== 'Access denied!') {
      message = req.session.error;
    }
  } else {
    message = req.session.success;
  }
  res.render('login', { title: msg(req, 'page.login'), message: message });
});

/** Wrap the callback-based authenticate() so the handler can stay async. */
function authenticateAsync(name, pass) {
  return new Promise(function(resolve) {
    auth.authenticate(name, pass, function(err, user) {
      resolve(err ? null : user || null);
    });
  });
}

const PENDING_TTL_MS = 5 * 60 * 1000;

/** Start a session for a fully authenticated user. */
function finishLogin(req, res, next, user, redirectTo) {
  req.session.regenerate(function(regenErr) {
    if (regenErr) return next(regenErr);
    delete req.session.pending2fa;
    req.session.user = user;
    req.session.success = msg(req, 'msg.authenticatedAs', { name: user.name });
    if (user.pass_set) {
      res.redirect(safeRedirect(redirectTo));
    } else {
      res.redirect('/users/' + encodeURIComponent(user.name) + '/password');
    }
  });
}

router.post('/login', async function(req, res, next) {
  const username = typeof req.body.username === 'string' ? req.body.username : '';
  const password = typeof req.body.password === 'string' ? req.body.password : '';

  if (isThrottled(req, 'password', username)) {
    res.setHeader('Retry-After', '900');
    return res.status(429).render('login', {
      title: msg(req, 'page.login'),
      message: msg(req, 'msg.tooManyAttempts')
    });
  }

  if (!username || !password || username.length > 128 || password.length > 160) {
    recordFailure(req, 'password', username);
    return res.status(401).render('login', {
      title: msg(req, 'page.login'),
      message: msg(req, 'msg.authFailed')
    });
  }

  try {
    const user = await authenticateAsync(username, password);
    if (!user) {
      recordFailure(req, 'password', username);
      return res.status(401).render('login', {
        title: msg(req, 'page.login'),
        message: msg(req, 'msg.authFailed')
      });
    }

    // Password is correct. When any second factor is on, stop here and ask for
    // one of them; nothing is granted until it is verified. An account may have
    // both a passkey and TOTP enabled, so the sign-in page offers whichever
    // factors are configured and the user picks one.
    const passkeyState = await usersController.passkey_status(user.name);
    const totpState = await usersController.totp_status(user.name);
    const methods = [];
    if (passkeyState.enabled) methods.push('passkey');
    if (totpState.enabled) methods.push('totp');
    if (methods.length) {
      clearFailures(req, 'password', username);
      const redirectTo = safeRedirect(req.query.redirect);
      req.session.regenerate(function(regenErr) {
        if (regenErr) return next(regenErr);
        req.session.pending2fa = {
          name: user.name,
          pass_set: !!user.pass_set,
          redirect: redirectTo,
          methods,
          issued_at: Date.now()
        };
        res.redirect('/login/2fa');
      });
      return;
    }

    clearFailures(req, 'password', username);
    finishLogin(req, res, next, user, req.query.redirect);
  } catch (err) {
    next(err);
  }
});

router.get('/login/2fa', function(req, res) {
  const pending = req.session.pending2fa;
  if (!pending || Date.now() - pending.issued_at > PENDING_TTL_MS) {
    delete req.session.pending2fa;
    return res.redirect('/login');
  }
  const methods = Array.isArray(pending.methods) ? pending.methods : [];
  const rp = usersController.passkey_rp(req);
  res.render('login2fa', {
    title: msg(req, 'page.twoFactor'),
    name: pending.name,
    usePasskey: methods.indexOf('passkey') >= 0,
    useTotp: methods.indexOf('totp') >= 0,
    passkeyAvailable: rp.ok,
    message: null
  });
});

router.post('/login/2fa', async function(req, res, next) {
  const pending = req.session.pending2fa;

  if (!pending || Date.now() - pending.issued_at > PENDING_TTL_MS) {
    delete req.session.pending2fa;
    req.session.error = msg(req, 'msg.totpSessionExpired');
    return res.redirect('/login');
  }

  if (isThrottled(req, 'totp', pending.name)) {
    res.setHeader('Retry-After', '900');
    return res.status(429).render('login2fa', {
      title: msg(req, 'page.twoFactor'),
      name: pending.name,
      message: msg(req, 'msg.tooManyAttempts')
    });
  }

  const methods = Array.isArray(pending.methods) ? pending.methods : [];
  if (methods.indexOf('totp') < 0) {
    req.session.error = msg(req, 'msg.totpNotEnabled');
    return res.redirect('/login/2fa');
  }

  const code = typeof req.body.code === 'string' ? req.body.code : '';
  if (!code || code.length > 32) {
    recordFailure(req, 'totp', pending.name);
    return res.status(401).render('login2fa', {
      title: msg(req, 'page.twoFactor'),
      name: pending.name,
      usePasskey: methods.indexOf('passkey') >= 0,
      useTotp: true,
      passkeyAvailable: usersController.passkey_rp(req).ok,
      message: msg(req, 'msg.totpCodeInvalid')
    });
  }

  try {
    const check = await usersController.totp_check(pending.name, code);
    if (!check.ok) {
      recordFailure(req, 'totp', pending.name);
      return res.status(401).render('login2fa', {
        title: msg(req, 'page.twoFactor'),
        name: pending.name,
        usePasskey: methods.indexOf('passkey') >= 0,
        useTotp: true,
        passkeyAvailable: usersController.passkey_rp(req).ok,
        message: msg(req, 'msg.totpCodeInvalid')
      });
    }

    clearFailures(req, 'totp', pending.name);
    finishLogin(req, res, next, { name: pending.name, pass_set: pending.pass_set }, pending.redirect);
  } catch (err) {
    next(err);
  }
});

// --- passkey login ---------------------------------------------------------

function pendingOrRedirect(req, res) {
  const pending = req.session.pending2fa;
  if (!pending || Date.now() - pending.issued_at > PENDING_TTL_MS) {
    delete req.session.pending2fa;
    return null;
  }
  return pending;
}

// Kept so that old bookmarks and the previous redirect keep working; the
// combined page lists every configured factor.
router.get('/login/passkey', function(req, res) {
  if (!pendingOrRedirect(req, res)) return res.redirect('/login');
  res.redirect('/login/2fa');
});

function passkeyPending(req, res) {
  const pending = pendingOrRedirect(req, res);
  if (!pending) {
    res.status(401).json({ error: msg(req, 'msg.passkeyExpired') });
    return null;
  }
  const methods = Array.isArray(pending.methods) ? pending.methods : [];
  if (methods.indexOf('passkey') < 0) {
    res.status(401).json({ error: msg(req, 'msg.passkeyInvalid') });
    return null;
  }
  return pending;
}

router.post('/login/passkey/begin', async function(req, res) {
  const pending = passkeyPending(req, res);
  if (!pending) return;
  try {
    const options = await usersController.passkey_begin_authentication(req, pending.name);
    res.json(options);
  } catch (err) {
    res.status(400).json({ error: usersController.passkeyError(req, err.code || 'invalid') });
  }
});

router.post('/login/passkey/finish', async function(req, res, next) {
  const pending = passkeyPending(req, res);
  if (!pending) return;

  if (isThrottled(req, 'passkey', pending.name)) {
    res.setHeader('Retry-After', '900');
    return res.status(429).json({ error: msg(req, 'msg.tooManyAttempts') });
  }

  try {
    await usersController.passkey_finish_authentication(req, pending.name, req.body || {});
    clearFailures(req, 'passkey', pending.name);
    const redirectTo = pending.pass_set
      ? safeRedirect(pending.redirect)
      : '/users/' + encodeURIComponent(pending.name) + '/password';
    req.session.regenerate(function(regenErr) {
      if (regenErr) return next(regenErr);
      req.session.user = { name: pending.name, pass_set: pending.pass_set };
      req.session.success = msg(req, 'msg.authenticatedAs', { name: pending.name });
      res.json({ ok: true, redirect: redirectTo });
    });
  } catch (err) {
    recordFailure(req, 'passkey', pending.name);
    res.status(401).json({ error: usersController.passkeyError(req, err.code || 'invalid') });
  }
});

module.exports = router;
