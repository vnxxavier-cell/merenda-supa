(function (root) {
  'use strict';

  if (!root || root.AppV2) return;

  const FRONTEND_VERSION = '2.0.0';
  const API_VERSION = 2;
  const CACHE_VERSION = 1;
  const CACHE_SCHEMA = 'app-v2-school-state-cache';
  const OAUTH_MARKER = 'app_v2_oauth';
  const EVENT_TYPES = new Set([
    'gate',
    'connection',
    'auth',
    'save',
    'school-state',
    'invalid-session',
    'google-pending',
    'error'
  ]);
  const REQUIRED_FEATURES = [
    'supabase_auth',
    'profile_validation',
    'legacy_login',
    'google_oauth_claim',
    'school_state',
    'revisioned_save'
  ];
  const HOOK_NAMES = {
    gate: 'onGateStatus',
    connection: 'onConnectionStatus',
    auth: 'onAuthStatus',
    save: 'onSaveStatus',
    'school-state': 'onSchoolState',
    'invalid-session': 'onInvalidSession',
    'google-pending': 'onGooglePending',
    error: 'onError'
  };

  class AppV2Error extends Error {
    constructor(code, message, details, cause) {
      super(message);
      this.name = 'AppV2Error';
      this.code = code;
      if (details !== undefined) this.details = details;
      if (cause !== undefined) this.cause = cause;
    }
  }

  const config = {
    supabaseClient: null,
    supabaseUrl: '',
    supabaseAnonKey: '',
    supabaseFactory: null,
    clientOptions: null,
    fetch: null,
    expectedMigration: 'server-first-v2',
    rpc: {
      capabilities: 'app_v2_capabilities',
      sessionContext: 'app_v2_session_context',
      endSession: 'app_v2_end_session',
      loadSchoolState: 'app_v2_load_school_state',
      saveSchoolState: 'app_v2_save_school_state',
      captureLegacyState: 'app_v2_capture_legacy_browser_state'
    },
    functions: {
      legacyLogin: 'legacy-login',
      googleClaim: 'claim-google-login',
      adminUsers: 'admin-users'
    },
    redirectTo: '',
    googleQueryParams: null,
    cachePrefix: 'merenda:app-v2',
    cacheStorage: null,
    sessionValidationIntervalMs: 60000,
    adminRoles: ['admin', 'super_admin'],
    hooks: {}
  };

  const runtime = {
    configured: false,
    probeStarted: false,
    gatePromise: null,
    bootstrapPromise: null,
    sessionPromise: null,
    loadPromise: null,
    savePromise: null,
    client: null,
    active: false,
    gate: {
      status: 'idle',
      ready: false,
      reason: null,
      capabilities: null
    },
    connection: {
      status: 'unknown',
      reason: null,
      checkedAt: null
    },
    auth: {
      status: 'idle',
      reason: null,
      user: null,
      profile: null,
      schoolId: null,
      validatedAt: null
    },
    session: null,
    school: null,
    save: {
      status: 'idle',
      revision: null,
      reason: null,
      savedAt: null
    },
    listeners: new Map(),
    authSubscription: null,
    validationTimer: null,
    queuedValidationTimer: null,
    onlineHandler: null,
    offlineHandler: null,
    invalidating: false,
    loggingOut: false
  };

  function cloneJson(value) {
    if (value === undefined || value === null) return value;
    return JSON.parse(JSON.stringify(value));
  }

  function publicError(error) {
    if (!error) return null;
    return {
      name: error.name || 'Error',
      code: error.code || null,
      message: error.message || String(error),
      status: getErrorStatus(error)
    };
  }

  function emit(type, detail) {
    if (!runtime.active || !EVENT_TYPES.has(type)) return;
    const payload = cloneJson(detail);
    const listeners = runtime.listeners.get(type);
    if (listeners) {
      listeners.forEach(function (listener) {
        try { listener(payload); } catch (_) {}
      });
    }

    const hook = config.hooks[HOOK_NAMES[type]];
    if (typeof hook === 'function') {
      try { hook(payload); } catch (_) {}
    }

    if (typeof root.dispatchEvent === 'function' && typeof root.CustomEvent === 'function') {
      try {
        root.dispatchEvent(new root.CustomEvent('appv2:' + type, { detail: payload }));
      } catch (_) {}
    }
  }

  function emitError(error, operation) {
    emit('error', {
      operation: operation,
      error: publicError(error),
      at: new Date().toISOString()
    });
  }

  function setConnection(status, reason, operation) {
    runtime.connection = {
      status: status,
      reason: reason || null,
      operation: operation || null,
      checkedAt: new Date().toISOString()
    };
    emit('connection', runtime.connection);
  }

  function setAuthStatus(status, reason, source) {
    runtime.auth.status = status;
    runtime.auth.reason = reason || null;
    emit('auth', {
      status: status,
      reason: reason || null,
      source: source || null,
      user: publicUser(runtime.auth.user),
      profile: cloneJson(runtime.auth.profile),
      schoolId: runtime.auth.schoolId,
      validatedAt: runtime.auth.validatedAt
    });
  }

  function setSaveStatus(status, details) {
    details = details || {};
    runtime.save = {
      status: status,
      revision: details.revision !== undefined
        ? details.revision
        : (runtime.school ? runtime.school.revision : null),
      reason: details.reason || null,
      savedAt: details.savedAt || null,
      error: details.error || null
    };
    emit('save', runtime.save);
  }

  function publicUser(user) {
    if (!user) return null;
    return {
      id: user.id,
      email: user.email || null,
      app_metadata: cloneJson(user.app_metadata || {}),
      user_metadata: cloneJson(user.user_metadata || {})
    };
  }

  function getStatus() {
    return {
      frontendVersion: FRONTEND_VERSION,
      apiVersion: API_VERSION,
      active: runtime.active,
      gate: cloneJson(runtime.gate),
      connection: cloneJson(runtime.connection),
      auth: {
        status: runtime.auth.status,
        reason: runtime.auth.reason,
        user: publicUser(runtime.auth.user),
        profile: cloneJson(runtime.auth.profile),
        schoolId: runtime.auth.schoolId,
        validatedAt: runtime.auth.validatedAt
      },
      save: cloneJson(runtime.save),
      school: runtime.school ? {
        schoolId: runtime.school.schoolId,
        revision: runtime.school.revision,
        updatedAt: runtime.school.updatedAt
      } : null
    };
  }

  function on(type, listener) {
    if (!EVENT_TYPES.has(type)) {
      throw new AppV2Error('INVALID_EVENT', 'Unknown AppV2 event: ' + type);
    }
    if (typeof listener !== 'function') {
      throw new AppV2Error('INVALID_LISTENER', 'The event listener must be a function.');
    }
    if (!runtime.listeners.has(type)) runtime.listeners.set(type, new Set());
    runtime.listeners.get(type).add(listener);
    return function unsubscribe() {
      const listeners = runtime.listeners.get(type);
      if (listeners) listeners.delete(listener);
    };
  }

  function validateName(value, label, allowHyphen) {
    const pattern = allowHyphen
      ? /^[A-Za-z_][A-Za-z0-9_-]*$/
      : /^[A-Za-z_][A-Za-z0-9_]*$/;
    if (typeof value !== 'string' || !pattern.test(value)) {
      throw new AppV2Error('INVALID_CONFIG', label + ' has an invalid name.');
    }
    return value;
  }

  function configure(options) {
    if (runtime.probeStarted) {
      throw new AppV2Error('CONFIG_LOCKED', 'Configure AppV2 before checking capabilities.');
    }
    if (runtime.configured) {
      throw new AppV2Error('ALREADY_CONFIGURED', 'AppV2 can only be configured once.');
    }
    options = options || {};
    if (typeof options !== 'object' || Array.isArray(options)) {
      throw new AppV2Error('INVALID_CONFIG', 'AppV2 configuration must be an object.');
    }

    if (options.supabaseClient !== undefined) config.supabaseClient = options.supabaseClient;
    if (options.supabaseUrl !== undefined) config.supabaseUrl = String(options.supabaseUrl).replace(/\/+$/, '');
    if (options.supabaseAnonKey !== undefined) config.supabaseAnonKey = String(options.supabaseAnonKey);
    if (options.supabaseFactory !== undefined) config.supabaseFactory = options.supabaseFactory;
    if (options.clientOptions !== undefined) config.clientOptions = cloneJson(options.clientOptions);
    if (options.fetch !== undefined) config.fetch = options.fetch;
    if (options.expectedMigration !== undefined) config.expectedMigration = String(options.expectedMigration);
    if (options.redirectTo !== undefined) config.redirectTo = String(options.redirectTo);
    if (options.googleQueryParams !== undefined) config.googleQueryParams = cloneJson(options.googleQueryParams);
    if (options.cachePrefix !== undefined) config.cachePrefix = String(options.cachePrefix);
    if (options.cacheStorage !== undefined) config.cacheStorage = options.cacheStorage;

    if (options.sessionValidationIntervalMs !== undefined) {
      const interval = Number(options.sessionValidationIntervalMs);
      if (!Number.isFinite(interval) || interval < 0) {
        throw new AppV2Error('INVALID_CONFIG', 'sessionValidationIntervalMs must be zero or a positive number.');
      }
      config.sessionValidationIntervalMs = interval;
    }

    if (options.adminRoles !== undefined) {
      if (!Array.isArray(options.adminRoles) || options.adminRoles.some(function (role) {
        return typeof role !== 'string' || !role;
      })) {
        throw new AppV2Error('INVALID_CONFIG', 'adminRoles must be an array of role names.');
      }
      config.adminRoles = options.adminRoles.slice();
    }

    if (options.rpc !== undefined) {
      const rpc = options.rpc || {};
      Object.keys(config.rpc).forEach(function (key) {
        if (rpc[key] !== undefined) config.rpc[key] = validateName(rpc[key], 'rpc.' + key, false);
      });
    }

    if (options.functions !== undefined) {
      const functions = options.functions || {};
      Object.keys(config.functions).forEach(function (key) {
        if (functions[key] !== undefined) {
          config.functions[key] = validateName(functions[key], 'functions.' + key, true);
        }
      });
    }

    if (options.hooks !== undefined) {
      if (!options.hooks || typeof options.hooks !== 'object' || Array.isArray(options.hooks)) {
        throw new AppV2Error('INVALID_CONFIG', 'hooks must be an object.');
      }
      Object.keys(HOOK_NAMES).forEach(function (eventType) {
        const hookName = HOOK_NAMES[eventType];
        if (options.hooks[hookName] !== undefined && typeof options.hooks[hookName] !== 'function') {
          throw new AppV2Error('INVALID_CONFIG', 'hooks.' + hookName + ' must be a function.');
        }
      });
      config.hooks = Object.assign({}, options.hooks);
    }

    if (config.supabaseFactory !== null && typeof config.supabaseFactory !== 'function') {
      throw new AppV2Error('INVALID_CONFIG', 'supabaseFactory must be a function.');
    }
    if (config.fetch !== null && typeof config.fetch !== 'function') {
      throw new AppV2Error('INVALID_CONFIG', 'fetch must be a function.');
    }
    if (!config.expectedMigration || !config.cachePrefix) {
      throw new AppV2Error('INVALID_CONFIG', 'expectedMigration and cachePrefix cannot be empty.');
    }

    runtime.configured = true;
    return api;
  }

  function normalizeRow(data) {
    if (Array.isArray(data)) return data.length === 1 ? data[0] : data;
    return data;
  }

  function capabilityResult(status, ready, reason, capabilities, error) {
    runtime.gate = {
      status: status,
      ready: ready,
      reason: reason || null,
      capabilities: capabilities ? cloneJson(capabilities) : null,
      error: error ? publicError(error) : null
    };
    return cloneJson(runtime.gate);
  }

  function validateCapabilities(value) {
    const capabilities = normalizeRow(value);
    if (!capabilities || typeof capabilities !== 'object' || Array.isArray(capabilities)) {
      return { ready: false, reason: 'invalid-capability-response' };
    }
    if (capabilities.ready !== true) {
      return {
        ready: false,
        reason: typeof capabilities.reason === 'string' ? capabilities.reason : 'migration-not-ready'
      };
    }
    if (capabilities.migration !== config.expectedMigration || capabilities.api_version !== API_VERSION) {
      return { ready: false, reason: 'capability-contract-mismatch' };
    }
    if (!capabilities.features || typeof capabilities.features !== 'object') {
      return { ready: false, reason: 'capability-contract-mismatch' };
    }
    const missing = REQUIRED_FEATURES.filter(function (feature) {
      return capabilities.features[feature] !== true;
    });
    if (missing.length) {
      return { ready: false, reason: 'missing-capabilities:' + missing.join(',') };
    }
    return { ready: true, capabilities: capabilities };
  }

  async function probeCapabilities() {
    if (config.supabaseClient) {
      if (typeof config.supabaseClient.rpc !== 'function') {
        throw new AppV2Error('INVALID_CLIENT', 'The supplied Supabase client has no rpc method.');
      }
      const result = await config.supabaseClient.rpc(config.rpc.capabilities, {});
      if (result && result.error) throw result.error;
      return result ? result.data : null;
    }

    if (!config.supabaseUrl || !config.supabaseAnonKey) {
      throw new AppV2Error(
        'NOT_CONFIGURED',
        'Supply supabaseClient, or supabaseUrl and supabaseAnonKey, before bootstrap.'
      );
    }
    const fetchImpl = config.fetch || (typeof root.fetch === 'function' ? root.fetch.bind(root) : null);
    if (!fetchImpl) throw new AppV2Error('FETCH_UNAVAILABLE', 'No fetch implementation is available.');

    const endpoint = config.supabaseUrl + '/rest/v1/rpc/' + encodeURIComponent(config.rpc.capabilities);
    const response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        apikey: config.supabaseAnonKey,
        Authorization: 'Bearer ' + config.supabaseAnonKey,
        Accept: 'application/json',
        'Content-Type': 'application/json'
      },
      body: '{}'
    });
    if (!response || !response.ok) {
      const error = new AppV2Error('CAPABILITY_HTTP_ERROR', 'Capability RPC was unavailable.');
      error.status = response ? response.status : null;
      throw error;
    }
    return response.json();
  }

  async function checkCapability(options) {
    options = options || {};
    runtime.probeStarted = true;
    if (runtime.gate.ready && !options.force) return cloneJson(runtime.gate);
    if (runtime.gatePromise) return runtime.gatePromise;

    runtime.gate.status = 'checking';
    runtime.gate.reason = null;
    runtime.gatePromise = (async function () {
      try {
        const raw = await probeCapabilities();
        const checked = validateCapabilities(raw);
        if (!checked.ready) {
          return capabilityResult('unavailable', false, checked.reason, null, null);
        }
        return capabilityResult('ready', true, null, checked.capabilities, null);
      } catch (error) {
        return capabilityResult('unavailable', false, 'capability-unavailable', null, error);
      } finally {
        runtime.gatePromise = null;
      }
    })();
    return runtime.gatePromise;
  }

  function resolveClient() {
    if (runtime.client) return runtime.client;
    if (config.supabaseClient) {
      runtime.client = config.supabaseClient;
      return runtime.client;
    }

    let factory = config.supabaseFactory;
    if (!factory && root.supabase && typeof root.supabase.createClient === 'function') {
      factory = root.supabase.createClient.bind(root.supabase);
    }
    if (!factory) {
      throw new AppV2Error('SUPABASE_SDK_UNAVAILABLE', 'The Supabase browser SDK is not available.');
    }
    runtime.client = factory(config.supabaseUrl, config.supabaseAnonKey, config.clientOptions || undefined);
    return runtime.client;
  }

  function validateClient(client) {
    const authMethods = [
      'getSession',
      'getUser',
      'setSession',
      'signInWithOAuth',
      'linkIdentity',
      'signOut',
      'onAuthStateChange'
    ];
    if (!client || typeof client.rpc !== 'function' || !client.auth || !client.functions) {
      throw new AppV2Error('INVALID_CLIENT', 'The Supabase client does not provide the required APIs.');
    }
    if (typeof client.functions.invoke !== 'function' || authMethods.some(function (method) {
      return typeof client.auth[method] !== 'function';
    })) {
      throw new AppV2Error('INVALID_CLIENT', 'The Supabase client does not provide the required Auth APIs.');
    }
  }

  function queueSessionValidation(source) {
    if (runtime.queuedValidationTimer || runtime.invalidating || runtime.loggingOut) return;
    runtime.queuedValidationTimer = root.setTimeout(function () {
      runtime.queuedValidationTimer = null;
      if (!runtime.active || runtime.auth.status !== 'authenticated') return;
      validateSession({ source: source || 'auth-event' }).catch(function (error) {
        emitError(error, 'validate-session');
      });
    }, 0);
  }

  function handleAuthStateChange(event, session) {
    if (!runtime.active || runtime.invalidating || runtime.loggingOut) return;
    if (event === 'SIGNED_OUT') {
      clearConfirmedCacheFor(runtime.auth.user, runtime.auth.schoolId);
      resetAuthData();
      setAuthStatus('anonymous', 'signed-out', 'auth-event');
      return;
    }
    if ((event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED') && !session) {
      invalidateSession('missing-session-after-auth-event').catch(function () {});
      return;
    }
    if (event === 'TOKEN_REFRESHED' || event === 'USER_UPDATED' ||
        (event === 'SIGNED_IN' && runtime.auth.status === 'authenticated')) {
      queueSessionValidation(event.toLowerCase());
    }
  }

  function activate() {
    if (runtime.active) return;
    const client = resolveClient();
    validateClient(client);

    const authResult = client.auth.onAuthStateChange(handleAuthStateChange);
    runtime.authSubscription = authResult && authResult.data
      ? authResult.data.subscription
      : authResult;

    runtime.onlineHandler = function () {
      setConnection('checking', null, 'browser-online');
      if (runtime.auth.status === 'authenticated') queueSessionValidation('browser-online');
    };
    runtime.offlineHandler = function () {
      setConnection('offline', 'browser-offline', 'browser-offline');
    };
    if (typeof root.addEventListener === 'function') {
      root.addEventListener('online', runtime.onlineHandler);
      root.addEventListener('offline', runtime.offlineHandler);
    }

    if (config.sessionValidationIntervalMs > 0 && typeof root.setInterval === 'function') {
      runtime.validationTimer = root.setInterval(function () {
        if (runtime.auth.status === 'authenticated') queueSessionValidation('interval');
      }, config.sessionValidationIntervalMs);
    }

    runtime.active = true;
    emit('gate', {
      status: 'ready',
      ready: true,
      capabilities: cloneJson(runtime.gate.capabilities)
    });
    if (root.navigator && root.navigator.onLine === false) {
      setConnection('offline', 'browser-offline', 'activation');
    }
  }

  async function ensureReady() {
    const gate = await checkCapability();
    if (!gate.ready) {
      throw new AppV2Error('MIGRATION_NOT_READY', 'The AppV2 backend capability gate is not ready.', {
        reason: gate.reason
      });
    }
    activate();
    return gate;
  }

  function getErrorStatus(error) {
    if (!error) return null;
    if (typeof error.status === 'number') return error.status;
    if (error.context && typeof error.context.status === 'number') return error.context.status;
    if (error.response && typeof error.response.status === 'number') return error.response.status;
    return null;
  }

  function isNetworkError(error) {
    if (root.navigator && root.navigator.onLine === false) return true;
    const message = String(error && error.message ? error.message : error || '').toLowerCase();
    return error && error.name === 'TypeError' ||
      /failed to fetch|networkerror|network request|load failed|fetch failed|offline/.test(message);
  }

  function isInvalidSessionError(error) {
    const status = getErrorStatus(error);
    if (status === 401) return true;
    const code = String(error && error.code ? error.code : '').toLowerCase();
    const message = String(error && error.message ? error.message : '').toLowerCase();
    return /jwt.*expired|invalid.*jwt|bad_jwt|refresh_token_not_found|session_not_found|invalid_grant/.test(
      code + ' ' + message
    );
  }

  function markServerError(error, operation) {
    if (isNetworkError(error)) {
      setConnection('offline', 'network-error', operation);
    } else {
      setConnection('online', null, operation);
    }
  }

  async function callRpc(name, args, operation) {
    setConnection('checking', null, operation);
    let result;
    try {
      result = await runtime.client.rpc(name, args || {});
    } catch (error) {
      markServerError(error, operation);
      if (isInvalidSessionError(error)) await invalidateSession('invalid-session', error);
      throw new AppV2Error('RPC_FAILED', 'The server request failed.', { operation: operation }, error);
    }
    if (result && result.error) {
      markServerError(result.error, operation);
      if (isInvalidSessionError(result.error)) await invalidateSession('invalid-session', result.error);
      throw new AppV2Error('RPC_FAILED', 'The server request failed.', { operation: operation }, result.error);
    }
    setConnection('online', null, operation);
    return normalizeRow(result ? result.data : null);
  }

  async function callFunction(name, body, operation) {
    setConnection('checking', null, operation);
    let result;
    try {
      result = await runtime.client.functions.invoke(name, { body: body || {} });
    } catch (error) {
      markServerError(error, operation);
      if (isInvalidSessionError(error)) await invalidateSession('invalid-session', error);
      throw new AppV2Error('FUNCTION_FAILED', 'The server function request failed.', { operation: operation }, error);
    }
    if (result && result.error) {
      markServerError(result.error, operation);
      if (isInvalidSessionError(result.error)) await invalidateSession('invalid-session', result.error);
      throw new AppV2Error('FUNCTION_FAILED', 'The server function request failed.', { operation: operation }, result.error);
    }
    setConnection('online', null, operation);
    return normalizeRow(result ? result.data : null);
  }

  async function callGetUser() {
    setConnection('checking', null, 'auth-get-user');
    let result;
    try {
      result = await runtime.client.auth.getUser();
    } catch (error) {
      markServerError(error, 'auth-get-user');
      if (isInvalidSessionError(error)) await invalidateSession('invalid-session', error);
      throw new AppV2Error('AUTH_VALIDATION_FAILED', 'Unable to validate the Auth user.', null, error);
    }
    if (result && result.error) {
      markServerError(result.error, 'auth-get-user');
      if (isInvalidSessionError(result.error)) await invalidateSession('invalid-session', result.error);
      throw new AppV2Error('AUTH_VALIDATION_FAILED', 'Unable to validate the Auth user.', null, result.error);
    }
    setConnection('online', null, 'auth-get-user');
    return result && result.data ? result.data.user : null;
  }

  function isDateExpired(value) {
    if (!value) return false;
    let candidate = String(value);
    if (/^\d{4}-\d{2}-\d{2}$/.test(candidate)) candidate += 'T23:59:59.999Z';
    const timestamp = Date.parse(candidate);
    return Number.isFinite(timestamp) && timestamp <= Date.now();
  }

  function validateSessionContext(value, authUser) {
    const context = normalizeRow(value);
    if (!context || typeof context !== 'object' || Array.isArray(context)) {
      throw new AppV2Error('INVALID_SESSION_CONTRACT', 'Session context RPC returned an invalid payload.');
    }
    if (context.valid !== true) {
      return {
        valid: false,
        reason: typeof context.reason === 'string' ? context.reason : 'profile-invalid'
      };
    }

    const profile = context.profile;
    if (!profile || typeof profile !== 'object' || Array.isArray(profile)) {
      throw new AppV2Error('INVALID_SESSION_CONTRACT', 'Session context has no profile.');
    }
    if (!authUser || typeof authUser.id !== 'string' || profile.auth_user_id !== authUser.id) {
      return { valid: false, reason: 'auth-profile-mismatch' };
    }
    if (context.auth_user_id !== undefined && context.auth_user_id !== authUser.id) {
      return { valid: false, reason: 'auth-context-mismatch' };
    }
    if (profile.active !== true) return { valid: false, reason: 'profile-inactive' };
    if (isDateExpired(profile.expires_at)) return { valid: false, reason: 'profile-expired' };
    if (typeof profile.id !== 'string' || !profile.id || typeof profile.role !== 'string' || !profile.role) {
      throw new AppV2Error('INVALID_SESSION_CONTRACT', 'Session profile is missing required fields.');
    }

    const schoolId = context.school_id !== undefined ? context.school_id : profile.school_id;
    if (context.school_id !== undefined && profile.school_id !== undefined &&
        context.school_id !== profile.school_id) {
      return { valid: false, reason: 'school-context-mismatch' };
    }
    if (!config.adminRoles.includes(profile.role) && (typeof schoolId !== 'string' || !schoolId)) {
      return { valid: false, reason: 'school-missing' };
    }

    return {
      valid: true,
      profile: cloneJson(profile),
      schoolId: typeof schoolId === 'string' && schoolId ? schoolId : null
    };
  }

  function userHasGoogleProvider(user) {
    if (!user) return false;
    const metadata = user.app_metadata || {};
    if (metadata.provider === 'google') return true;
    return Array.isArray(metadata.providers) && metadata.providers.includes('google');
  }

  async function claimGoogleAccount(authUser) {
    if (!userHasGoogleProvider(authUser)) {
      throw new AppV2Error('NOT_GOOGLE_SESSION', 'The current Auth session is not a Google session.');
    }
    const response = await callFunction(
      config.functions.googleClaim,
      { provider: 'google' },
      'google-claim'
    );
    if (!response || response.ok !== true) {
      const reason = response && typeof response.code === 'string'
        ? response.code
        : 'google-claim-rejected';
      await invalidateSession(reason);
      throw new AppV2Error('GOOGLE_CLAIM_REJECTED', 'Google account claim was rejected.', { reason: reason });
    }
    if (response.status === 'pending') {
      return {
        status: 'pending',
        message: typeof response.message === 'string' && response.message
          ? response.message
          : 'Aguardando aprovação do administrador.'
      };
    }
    if (response.status !== 'approved' || response.authorized !== true) {
      await invalidateSession('google-claim-rejected');
      throw new AppV2Error('GOOGLE_CLAIM_REJECTED', 'Google account claim was rejected.', {
        reason: 'google-claim-rejected'
      });
    }
    return { status: 'approved' };
  }

  function resetAuthData() {
    runtime.session = null;
    runtime.auth.user = null;
    runtime.auth.profile = null;
    runtime.auth.schoolId = null;
    runtime.auth.validatedAt = null;
    runtime.school = null;
    setSaveStatus('idle', { revision: null });
  }

  async function invalidateSession(reason, error) {
    if (runtime.invalidating) return;
    runtime.invalidating = true;
    const previousUser = runtime.auth.user;
    const previousSchoolId = runtime.auth.schoolId;
    clearConfirmedCacheFor(previousUser, previousSchoolId);
    resetAuthData();
    runtime.auth.status = 'invalid';
    runtime.auth.reason = reason || 'invalid-session';
    emit('invalid-session', {
      reason: runtime.auth.reason,
      error: publicError(error),
      at: new Date().toISOString()
    });
    setAuthStatus('invalid', runtime.auth.reason, 'server-validation');
    try {
      if (runtime.client && runtime.client.auth && typeof runtime.client.auth.signOut === 'function') {
        await runtime.client.auth.signOut({ scope: 'local' });
      }
    } catch (_) {
      // Runtime state is still cleared when the remote session is already unusable.
    } finally {
      runtime.invalidating = false;
    }
  }

  function isOAuthCallback() {
    if (!root.location || !root.location.href) return false;
    try {
      const url = new URL(root.location.href);
      return url.searchParams.get(OAUTH_MARKER) === 'google';
    } catch (_) {
      return false;
    }
  }

  function snapshot() {
    return {
      ready: runtime.gate.ready,
      authenticated: runtime.auth.status === 'authenticated',
      authStatus: runtime.auth.status,
      reason: runtime.auth.reason,
      user: publicUser(runtime.auth.user),
      profile: cloneJson(runtime.auth.profile),
      school: getSchoolState()
    };
  }

  async function performSessionValidation(options) {
    options = options || {};
    const previousStatus = runtime.auth.status;
    setAuthStatus('validating', null, options.source || 'bootstrap');

    let sessionResult;
    try {
      sessionResult = await runtime.client.auth.getSession();
    } catch (error) {
      markServerError(error, 'auth-get-session');
      if (isInvalidSessionError(error)) await invalidateSession('invalid-session', error);
      throw new AppV2Error('AUTH_SESSION_FAILED', 'Unable to read the Auth session.', null, error);
    }
    if (sessionResult && sessionResult.error) {
      markServerError(sessionResult.error, 'auth-get-session');
      if (isInvalidSessionError(sessionResult.error)) {
        await invalidateSession('invalid-session', sessionResult.error);
      }
      throw new AppV2Error('AUTH_SESSION_FAILED', 'Unable to read the Auth session.', null, sessionResult.error);
    }

    const session = sessionResult && sessionResult.data ? sessionResult.data.session : null;
    if (!session) {
      if (options.expectSession || previousStatus === 'authenticated') {
        await invalidateSession('session-missing');
      } else {
        resetAuthData();
        setAuthStatus('anonymous', 'session-missing', options.source || 'bootstrap');
      }
      return snapshot();
    }

    const authUser = await callGetUser();
    if (!authUser || !session.user || authUser.id !== session.user.id) {
      await invalidateSession('auth-user-mismatch');
      return snapshot();
    }

    if (options.claimGoogle === true) {
      const claim = await claimGoogleAccount(authUser);
      if (claim.status === 'pending') {
        await invalidateSession('google-pending-approval');
        emit('google-pending', {
          message: claim.message,
          at: new Date().toISOString()
        });
        return snapshot();
      }
    }

    const contextPayload = await callRpc(config.rpc.sessionContext, {}, 'session-context');
    const context = validateSessionContext(contextPayload, authUser);
    if (!context.valid) {
      await invalidateSession(context.reason);
      return snapshot();
    }

    if (runtime.auth.user && runtime.auth.user.id !== authUser.id) {
      clearConfirmedCacheFor(runtime.auth.user, runtime.auth.schoolId);
      runtime.school = null;
    }
    runtime.session = session;
    runtime.auth.user = authUser;
    runtime.auth.profile = context.profile;
    runtime.auth.schoolId = context.schoolId;
    runtime.auth.validatedAt = new Date().toISOString();
    setAuthStatus('authenticated', null, options.source || 'bootstrap');

    if (options.loadState !== false && context.schoolId) await loadSchoolState();
    return snapshot();
  }

  function establishSession(options) {
    if (runtime.sessionPromise) return runtime.sessionPromise;
    runtime.sessionPromise = performSessionValidation(options).catch(function (error) {
      if (runtime.auth.status !== 'invalid') {
        setAuthStatus('error', error.code || 'session-validation-failed', options && options.source);
      }
      throw error;
    }).finally(function () {
      runtime.sessionPromise = null;
    });
    return runtime.sessionPromise;
  }

  async function bootstrap(options) {
    options = options || {};
    if (runtime.bootstrapPromise) return runtime.bootstrapPromise;
    runtime.bootstrapPromise = (async function () {
      const gate = await checkCapability();
      if (!gate.ready) {
        return {
          ready: false,
          authenticated: false,
          reason: gate.reason,
          gate: gate
        };
      }
      activate();
      return establishSession({
        source: 'bootstrap',
        loadState: options.loadSchoolState !== false,
        claimGoogle: options.claimGoogle === true || isOAuthCallback(),
        expectSession: false
      });
    })().finally(function () {
      runtime.bootstrapPromise = null;
    });
    return runtime.bootstrapPromise;
  }

  async function validateSession(options) {
    options = options || {};
    await ensureReady();
    return establishSession({
      source: options.source || 'manual-validation',
      loadState: false,
      claimGoogle: false,
      expectSession: runtime.auth.status === 'authenticated'
    });
  }

  function requireAnonymous() {
    if (runtime.auth.status === 'authenticated') {
      throw new AppV2Error('ALREADY_AUTHENTICATED', 'Log out before starting another sign-in.');
    }
  }

  async function signInWithPassword(username, password) {
    await ensureReady();
    requireAnonymous();
    if (typeof username !== 'string' || !username.trim() || typeof password !== 'string' || !password) {
      throw new AppV2Error('INVALID_CREDENTIAL_INPUT', 'Username and password are required.');
    }

    setAuthStatus('authenticating', null, 'legacy-login');
    let response;
    try {
      response = await callFunction(
        config.functions.legacyLogin,
        { username: username.trim(), password: password },
        'legacy-login'
      );
    } catch (error) {
      if (runtime.auth.status !== 'invalid') setAuthStatus('error', error.code, 'legacy-login');
      throw error;
    }

    if (!response || response.ok !== true) {
      const reason = response && typeof response.code === 'string'
        ? response.code
        : 'invalid-credentials';
      setAuthStatus('anonymous', reason, 'legacy-login');
      return { ok: false, reason: reason };
    }
    if (!response.session || typeof response.session.access_token !== 'string' ||
        typeof response.session.refresh_token !== 'string') {
      setAuthStatus('error', 'invalid-login-contract', 'legacy-login');
      throw new AppV2Error('INVALID_LOGIN_CONTRACT', 'legacy-login returned no usable Auth session.');
    }

    let setSessionResult;
    try {
      setSessionResult = await runtime.client.auth.setSession({
        access_token: response.session.access_token,
        refresh_token: response.session.refresh_token
      });
    } catch (error) {
      markServerError(error, 'auth-set-session');
      throw new AppV2Error('AUTH_SESSION_FAILED', 'Unable to establish the Auth session.', null, error);
    }
    if (setSessionResult && setSessionResult.error) {
      markServerError(setSessionResult.error, 'auth-set-session');
      throw new AppV2Error(
        'AUTH_SESSION_FAILED',
        'Unable to establish the Auth session.',
        null,
        setSessionResult.error
      );
    }

    const result = await establishSession({
      source: 'legacy-login',
      loadState: true,
      claimGoogle: false,
      expectSession: true
    });
    if (!result.authenticated) return { ok: false, reason: result.reason || 'invalid-session' };
    if (response.auth_user_id && response.auth_user_id !== result.user.id) {
      await invalidateSession('login-user-mismatch');
      return { ok: false, reason: 'login-user-mismatch' };
    }
    return Object.assign({ ok: true }, result);
  }

  function buildGoogleRedirect(redirectTo) {
    const target = redirectTo || config.redirectTo || (root.location && root.location.href);
    if (!target) throw new AppV2Error('INVALID_REDIRECT', 'A Google OAuth redirect URL is required.');
    let url;
    try {
      url = new URL(target, root.location && root.location.href ? root.location.href : undefined);
    } catch (error) {
      throw new AppV2Error('INVALID_REDIRECT', 'The Google OAuth redirect URL is invalid.', null, error);
    }
    url.searchParams.set(OAUTH_MARKER, 'google');
    url.hash = '';
    return url.toString();
  }

  async function signInWithGoogle(options) {
    options = options || {};
    await ensureReady();
    requireAnonymous();
    setAuthStatus('redirecting', null, 'google');

    const oauthOptions = {
      redirectTo: buildGoogleRedirect(options.redirectTo)
    };
    const queryParams = Object.assign({}, config.googleQueryParams || {}, options.queryParams || {});
    if (Object.keys(queryParams).length) oauthOptions.queryParams = queryParams;
    if (options.scopes) oauthOptions.scopes = String(options.scopes);
    if (options.skipBrowserRedirect === true) oauthOptions.skipBrowserRedirect = true;

    let result;
    try {
      result = await runtime.client.auth.signInWithOAuth({
        provider: 'google',
        options: oauthOptions
      });
    } catch (error) {
      markServerError(error, 'google-sign-in');
      setAuthStatus('error', 'google-sign-in-failed', 'google');
      throw new AppV2Error('GOOGLE_SIGN_IN_FAILED', 'Unable to start Google sign-in.', null, error);
    }
    if (result && result.error) {
      markServerError(result.error, 'google-sign-in');
      setAuthStatus('error', 'google-sign-in-failed', 'google');
      throw new AppV2Error('GOOGLE_SIGN_IN_FAILED', 'Unable to start Google sign-in.', null, result.error);
    }
    return {
      ok: true,
      redirectUrl: result && result.data && result.data.url ? result.data.url : null
    };
  }

  async function linkGoogleIdentity(options) {
    options = options || {};
    await ensureReady();
    requireSchoolSession();
    if (!runtime.auth.profile || !runtime.auth.profile.google_email) {
      throw new AppV2Error(
        'GOOGLE_NOT_PREAUTHORIZED',
        'An administrator must preauthorize the Google email before it can be linked.'
      );
    }
    const queryParams = Object.assign({}, config.googleQueryParams || {}, options.queryParams || {});
    const result = await runtime.client.auth.linkIdentity({
      provider: 'google',
      options: {
        redirectTo: buildGoogleRedirect(options.redirectTo),
        queryParams: queryParams
      }
    });
    if (result && result.error) {
      markServerError(result.error, 'google-link');
      throw new AppV2Error('GOOGLE_LINK_FAILED', 'Unable to link the Google identity.', null, result.error);
    }
    return {
      ok: true,
      redirectUrl: result && result.data && result.data.url ? result.data.url : null
    };
  }

  async function completeGoogleSignIn(options) {
    options = options || {};
    await ensureReady();
    const result = await establishSession({
      source: 'google-callback',
      loadState: options.loadSchoolState !== false,
      claimGoogle: true,
      expectSession: false
    });
    return Object.assign({ ok: result.authenticated }, result);
  }

  function cacheStorage() {
    try {
      return config.cacheStorage || root.localStorage || null;
    } catch (_) {
      return null;
    }
  }

  function cacheKey(authUserId, schoolId) {
    return config.cachePrefix + ':school-state:v' + CACHE_VERSION + ':' +
      encodeURIComponent(authUserId) + ':' + encodeURIComponent(schoolId);
  }

  function clearConfirmedCacheFor(user, schoolId) {
    if (!user || !user.id || !schoolId) return false;
    const storage = cacheStorage();
    if (!storage || typeof storage.removeItem !== 'function') return false;
    try {
      storage.removeItem(cacheKey(user.id, schoolId));
      return true;
    } catch (_) {
      return false;
    }
  }

  function writeConfirmedCache(record) {
    const storage = cacheStorage();
    if (!storage || typeof storage.setItem !== 'function') return false;
    const envelope = {
      schema: CACHE_SCHEMA,
      version: CACHE_VERSION,
      api_version: API_VERSION,
      confirmed_by: 'server',
      confirmed_at: new Date().toISOString(),
      auth_user_id: runtime.auth.user.id,
      school_id: record.schoolId,
      revision: record.revision,
      updated_at: record.updatedAt,
      state: cloneJson(record.state)
    };
    try {
      storage.setItem(cacheKey(runtime.auth.user.id, record.schoolId), JSON.stringify(envelope));
      return true;
    } catch (error) {
      emitError(new AppV2Error('CACHE_WRITE_FAILED', 'Confirmed state cache could not be written.'), 'cache-write');
      return false;
    }
  }

  function getCachedSchoolState() {
    if (!runtime.active || runtime.auth.status !== 'authenticated' ||
        !runtime.auth.user || !runtime.auth.schoolId) return null;
    const storage = cacheStorage();
    if (!storage || typeof storage.getItem !== 'function') return null;
    try {
      const raw = storage.getItem(cacheKey(runtime.auth.user.id, runtime.auth.schoolId));
      if (!raw) return null;
      const envelope = JSON.parse(raw);
      if (!envelope || envelope.schema !== CACHE_SCHEMA || envelope.version !== CACHE_VERSION ||
          envelope.api_version !== API_VERSION || envelope.confirmed_by !== 'server' ||
          envelope.auth_user_id !== runtime.auth.user.id ||
          envelope.school_id !== runtime.auth.schoolId || !isRevision(envelope.revision) ||
          !isStateObject(envelope.state)) {
        return null;
      }
      return {
        source: 'confirmed-cache',
        stale: true,
        confirmedAt: envelope.confirmed_at || null,
        schoolId: envelope.school_id,
        revision: envelope.revision,
        updatedAt: envelope.updated_at || null,
        state: cloneJson(envelope.state)
      };
    } catch (_) {
      return null;
    }
  }

  function isStateObject(value) {
    return !!value && typeof value === 'object' && !Array.isArray(value);
  }

  function isRevision(value) {
    return typeof value === 'number' && Number.isInteger(value) && value >= 0 ||
      typeof value === 'string' && value.length > 0;
  }

  function normalizeServerState(value, operation) {
    const payload = normalizeRow(value);
    if (!payload || typeof payload !== 'object' || Array.isArray(payload) ||
        payload.ok === false || typeof payload.school_id !== 'string' ||
        payload.school_id !== runtime.auth.schoolId || !isRevision(payload.revision) ||
        !isStateObject(payload.state)) {
      throw new AppV2Error('INVALID_STATE_CONTRACT', operation + ' returned an invalid state payload.');
    }
    return {
      source: 'server',
      schoolId: payload.school_id,
      revision: payload.revision,
      updatedAt: payload.updated_at || null,
      state: cloneJson(payload.state)
    };
  }

  function acceptServerState(value, source) {
    const record = normalizeServerState(value, source);
    runtime.school = record;
    const cached = writeConfirmedCache(record);
    emit('school-state', {
      source: source,
      schoolId: record.schoolId,
      revision: record.revision,
      updatedAt: record.updatedAt,
      cacheStored: cached,
      state: cloneJson(record.state)
    });
    return getSchoolState();
  }

  function requireSchoolSession() {
    if (!runtime.active || runtime.auth.status !== 'authenticated' || !runtime.session) {
      throw new AppV2Error('AUTH_REQUIRED', 'A validated AppV2 session is required.');
    }
    if (!runtime.auth.schoolId) {
      throw new AppV2Error('SCHOOL_REQUIRED', 'The validated profile has no school context.');
    }
  }

  function getSchoolState() {
    if (!runtime.school) return null;
    return {
      source: runtime.school.source,
      schoolId: runtime.school.schoolId,
      revision: runtime.school.revision,
      updatedAt: runtime.school.updatedAt,
      state: cloneJson(runtime.school.state)
    };
  }

  function loadSchoolState() {
    requireSchoolSession();
    if (runtime.loadPromise) return runtime.loadPromise;
    runtime.loadPromise = callRpc(config.rpc.loadSchoolState, {}, 'load-school-state')
      .then(function (payload) {
        return acceptServerState(payload, 'server-load');
      })
      .catch(function (error) {
        emitError(error, 'load-school-state');
        throw error;
      })
      .finally(function () {
        runtime.loadPromise = null;
      });
    return runtime.loadPromise;
  }

  function jsonState(value) {
    if (!isStateObject(value)) {
      throw new AppV2Error('INVALID_STATE', 'School state must be a JSON object.');
    }
    try {
      return cloneJson(value);
    } catch (error) {
      throw new AppV2Error('INVALID_STATE', 'School state must be JSON-serializable.', null, error);
    }
  }

  function requestId() {
    if (root.crypto && typeof root.crypto.randomUUID === 'function') return root.crypto.randomUUID();
    if (root.crypto && typeof root.crypto.getRandomValues === 'function') {
      const bytes = new Uint8Array(16);
      root.crypto.getRandomValues(bytes);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = Array.prototype.map.call(bytes, function (value) {
        return value.toString(16).padStart(2, '0');
      }).join('');
      return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' +
        hex.slice(16, 20) + '-' + hex.slice(20);
    }
    throw new AppV2Error('CRYPTO_UNAVAILABLE', 'A secure request ID generator is required.');
  }

  async function performSave(nextState, options) {
    requireSchoolSession();
    if (!runtime.school) {
      throw new AppV2Error('STATE_NOT_LOADED', 'Load server state before saving.');
    }
    const state = jsonState(nextState);
    const expectedRevision = options.expectedRevision !== undefined
      ? options.expectedRevision
      : runtime.school.revision;
    if (!isRevision(expectedRevision)) {
      throw new AppV2Error('INVALID_REVISION', 'A valid expected revision is required.');
    }

    setSaveStatus('saving', { revision: expectedRevision });
    try {
      const payload = await callRpc(config.rpc.saveSchoolState, {
        p_expected_revision: expectedRevision,
        p_state: state,
        p_request_id: options.requestId || requestId()
      }, 'save-school-state');

      if (payload && payload.ok === false && payload.code === 'revision_conflict') {
        if (!payload.current) {
          throw new AppV2Error('INVALID_STATE_CONTRACT', 'Revision conflict response has no current state.');
        }
        const current = acceptServerState(payload.current, 'save-conflict');
        setSaveStatus('conflict', {
          revision: current.revision,
          reason: 'revision-conflict'
        });
        return { ok: false, conflict: true, current: current };
      }

      const saved = acceptServerState(payload, 'server-save');
      setSaveStatus('saved', {
        revision: saved.revision,
        savedAt: new Date().toISOString()
      });
      return { ok: true, conflict: false, current: saved };
    } catch (error) {
      if (runtime.save.status !== 'conflict') {
        setSaveStatus('error', {
          reason: error.code || 'save-failed',
          error: publicError(error)
        });
      }
      emitError(error, 'save-school-state');
      throw error;
    }
  }

  function saveSchoolState(nextState, options) {
    if (runtime.savePromise) {
      throw new AppV2Error('SAVE_IN_PROGRESS', 'Wait for the current save to finish.');
    }
    options = options || {};
    runtime.savePromise = performSave(nextState, options).finally(function () {
      runtime.savePromise = null;
    });
    return runtime.savePromise;
  }

  async function captureLegacyBrowserState(payload, source) {
    requireSchoolSession();
    const state = jsonState(payload);
    const response = await callRpc(config.rpc.captureLegacyState, {
      p_payload: state,
      p_source: typeof source === 'string' && source.trim() ? source.trim().slice(0, 100) : 'browser-cache'
    }, 'capture-legacy-browser-state');
    if (!response || response.ok !== true || typeof response.snapshot_id !== 'string') {
      throw new AppV2Error('INVALID_CAPTURE_CONTRACT', 'Legacy cache capture returned an invalid response.');
    }
    return cloneJson(response);
  }

  async function logout(options) {
    options = options || {};
    await ensureReady();
    const scope = options.scope || 'global';
    if (!['global', 'local', 'others'].includes(scope)) {
      throw new AppV2Error('INVALID_LOGOUT_SCOPE', 'Invalid Supabase logout scope.');
    }

    runtime.loggingOut = true;
    setAuthStatus('signing-out', null, 'logout');
    const previousUser = runtime.auth.user;
    const previousSchoolId = runtime.auth.schoolId;
    let remoteError = null;
    try {
      if (runtime.auth.status === 'authenticated') {
        const endResult = await runtime.client.rpc(config.rpc.endSession, {});
        if (endResult && endResult.error && !isInvalidSessionError(endResult.error)) {
          remoteError = endResult.error;
        }
      }
      const result = await runtime.client.auth.signOut({ scope: scope });
      if (result && result.error && !remoteError) remoteError = result.error;
    } catch (error) {
      remoteError = error;
    }

    if (remoteError && scope !== 'local') {
      try { await runtime.client.auth.signOut({ scope: 'local' }); } catch (_) {}
      markServerError(remoteError, 'logout');
    } else if (!remoteError) {
      setConnection('online', null, 'logout');
    }

    clearConfirmedCacheFor(previousUser, previousSchoolId);
    resetAuthData();
    runtime.loggingOut = false;
    setAuthStatus('anonymous', 'logged-out', 'logout');
    return { ok: true, localOnly: !!remoteError };
  }

  function requireAdminSession() {
    if (!runtime.active || runtime.auth.status !== 'authenticated' || !runtime.auth.profile) {
      throw new AppV2Error('AUTH_REQUIRED', 'A validated AppV2 session is required.');
    }
    if (!config.adminRoles.includes(runtime.auth.profile.role)) {
      throw new AppV2Error('ADMIN_REQUIRED', 'The current profile is not an administrator.');
    }
    const features = runtime.gate.capabilities && runtime.gate.capabilities.features;
    if (!features || features.admin_users !== true) {
      throw new AppV2Error('ADMIN_USERS_UNAVAILABLE', 'The admin-users capability is not enabled.');
    }
  }

  async function adminRequest(action, payload) {
    requireAdminSession();
    if (typeof action !== 'string' || !action) {
      throw new AppV2Error('INVALID_ADMIN_ACTION', 'An admin-users action is required.');
    }
    const response = await callFunction(config.functions.adminUsers, {
      action: action,
      payload: payload || {}
    }, 'admin-users:' + action);
    if (!response || response.ok !== true) {
      const code = response && response.code ? response.code : 'admin-request-rejected';
      throw new AppV2Error('ADMIN_REQUEST_REJECTED', 'admin-users rejected the request.', { code: code });
    }
    return cloneJson(response);
  }

  function requireTargetId(targetUserId) {
    if (typeof targetUserId !== 'string' || !targetUserId) {
      throw new AppV2Error('INVALID_TARGET_USER', 'A target user ID is required.');
    }
    return targetUserId;
  }

  const adminUsers = Object.freeze({
    request: adminRequest,
    list: function (options) {
      return adminRequest('list', options || {});
    },
    get: function (targetUserId) {
      return adminRequest('get', { user_id: requireTargetId(targetUserId) });
    },
    create: function (user) {
      if (!user || typeof user !== 'object' || Array.isArray(user)) {
        throw new AppV2Error('INVALID_ADMIN_INPUT', 'User input must be an object.');
      }
      return adminRequest('create', { user: cloneJson(user) });
    },
    update: function (targetUserId, changes, expectedRevision) {
      if (!changes || typeof changes !== 'object' || Array.isArray(changes)) {
        throw new AppV2Error('INVALID_ADMIN_INPUT', 'User changes must be an object.');
      }
      return adminRequest('update', {
        user_id: requireTargetId(targetUserId),
        changes: cloneJson(changes),
        expected_revision: expectedRevision
      });
    },
    setActive: function (targetUserId, active, expectedRevision) {
      if (typeof active !== 'boolean') {
        throw new AppV2Error('INVALID_ADMIN_INPUT', 'active must be a boolean.');
      }
      return adminRequest('set-active', {
        user_id: requireTargetId(targetUserId),
        active: active,
        expected_revision: expectedRevision
      });
    },
    remove: function (targetUserId, expectedRevision) {
      return adminRequest('delete', {
        user_id: requireTargetId(targetUserId),
        expected_revision: expectedRevision
      });
    },
    cutoverReadiness: function () {
      return adminRequest('cutover-readiness', {});
    },
    approveCutover: function (backupReference) {
      if (typeof backupReference !== 'string' || !backupReference.trim()) {
        throw new AppV2Error('INVALID_BACKUP_REFERENCE', 'A backup reference is required.');
      }
      return adminRequest('approve-cutover', {
        backup_reference: backupReference.trim()
      });
    },
    assignLegacyTechnicalSheets: function (assignment) {
      if (!assignment || typeof assignment !== 'object' || Array.isArray(assignment)) {
        throw new AppV2Error('INVALID_ADMIN_INPUT', 'Technical-sheet assignment must be an object.');
      }
      return adminRequest('assign-legacy-technical-sheets', cloneJson(assignment));
    },
    googleRequests: function (options) {
      options = options || {};
      return adminRequest('google-requests', {
        include_resolved: options.includeResolved === true
      });
    },
    approveGoogle: function (request) {
      if (!request || typeof request !== 'object' || Array.isArray(request)) {
        throw new AppV2Error('INVALID_ADMIN_INPUT', 'Google approval must be an object.');
      }
      if (typeof request.login !== 'string' || !request.login.trim() ||
          typeof request.display_name !== 'string' || !request.display_name.trim()) {
        throw new AppV2Error('INVALID_ADMIN_INPUT', 'login and display_name are required.');
      }
      return adminRequest('google-approve', {
        auth_user_id: requireTargetId(request.auth_user_id),
        login: request.login.trim(),
        display_name: request.display_name.trim(),
        role: request.role === 'admin' ? 'admin' : 'escola',
        expires_at: request.expires_at || null,
        note: request.note || null
      });
    },
    rejectGoogle: function (authUserId, note) {
      return adminRequest('google-reject', {
        auth_user_id: requireTargetId(authUserId),
        note: note || null
      });
    },
    verifyFrontendV2: function (deploymentReference) {
      if (typeof deploymentReference !== 'string' || !deploymentReference.trim()) {
        throw new AppV2Error('INVALID_DEPLOYMENT_REFERENCE', 'A deployment reference is required.');
      }
      return adminRequest('frontend-v2-verify', {
        deployment_reference: deploymentReference.trim()
      });
    }
  });

  function destroy() {
    if (runtime.authSubscription && typeof runtime.authSubscription.unsubscribe === 'function') {
      try { runtime.authSubscription.unsubscribe(); } catch (_) {}
    }
    if (runtime.validationTimer) root.clearInterval(runtime.validationTimer);
    if (runtime.queuedValidationTimer) root.clearTimeout(runtime.queuedValidationTimer);
    if (typeof root.removeEventListener === 'function') {
      if (runtime.onlineHandler) root.removeEventListener('online', runtime.onlineHandler);
      if (runtime.offlineHandler) root.removeEventListener('offline', runtime.offlineHandler);
    }
    runtime.authSubscription = null;
    runtime.validationTimer = null;
    runtime.queuedValidationTimer = null;
    runtime.onlineHandler = null;
    runtime.offlineHandler = null;
    runtime.active = false;
  }

  const api = Object.freeze({
    version: FRONTEND_VERSION,
    apiVersion: API_VERSION,
    cacheVersion: CACHE_VERSION,
    AppV2Error: AppV2Error,
    configure: configure,
    checkCapability: checkCapability,
    bootstrap: bootstrap,
    validateSession: validateSession,
    signInWithPassword: signInWithPassword,
    signInWithGoogle: signInWithGoogle,
    linkGoogleIdentity: linkGoogleIdentity,
    completeGoogleSignIn: completeGoogleSignIn,
    logout: logout,
    loadSchoolState: loadSchoolState,
    saveSchoolState: saveSchoolState,
    captureLegacyBrowserState: captureLegacyBrowserState,
    getSchoolState: getSchoolState,
    getCachedSchoolState: getCachedSchoolState,
    getStatus: getStatus,
    on: on,
    adminUsers: adminUsers,
    destroy: destroy
  });

  Object.defineProperty(root, 'AppV2', {
    value: api,
    enumerable: true,
    configurable: false,
    writable: false
  });
})(window);
