(function (root) {
  'use strict';

  if (!root || root.AppV2Bridge) return;

  const LOGICAL_KEYS = [
    'merenda_niveis',
    'merenda_percapta',
    'merenda_embalagens',
    'merenda_licitacoes',
    'merenda_ordens_expedidas',
    'merenda_recebimentos',
    'merenda_estoque',
    'merenda_semanas_consumidas',
    'merenda_merc_ajustes',
    'merenda_servidores_config',
    'merenda_af_custom',
    'merenda_ciclos_planos',
    'merenda_unidades',
    'merenda_cal_config',
    'merenda_precos',
    'merenda_previas_contrato',
    'merenda_estoque_correcoes',
    'merenda_periodicidades',
    'merenda_ing_periodicidade',
    'merenda_cardapio',
    'merenda_header_img',
    'merenda_diretor',
    'merenda_cargo',
    'merenda_escola',
    'merenda_subtitulo',
    'merenda_fornecedores',
    'merenda_ing_fornecedores',
    'merenda_ing_unidade_venda',
    'merenda_ing_custom',
    'merenda_ing_ocultos',
    'merenda_ing_renomes',
    'merenda_semanas_consumir'
  ];

  const state = {
    configured: false,
    status: 'idle',
    reason: null,
    lastProbeAt: null,
    lastCaptureAt: null,
    lastHydrationAt: null,
    listeners: new Set()
  };

  const config = {
    supabaseUrl: '',
    supabaseAnonKey: '',
    supabaseClient: null,
    supabaseFactory: null,
    storage: null,
    onStatus: null
  };

  function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  }

  function emit() {
    const snapshot = getStatus();
    state.listeners.forEach(function (listener) {
      try { listener(snapshot); } catch (_) {}
    });
    if (typeof config.onStatus === 'function') {
      try { config.onStatus(snapshot); } catch (_) {}
    }
    if (typeof root.dispatchEvent === 'function' && typeof root.CustomEvent === 'function') {
      root.dispatchEvent(new root.CustomEvent('appv2bridge:status', { detail: snapshot }));
    }
  }

  function setStatus(status, reason) {
    state.status = status;
    state.reason = reason || null;
    state.lastProbeAt = new Date().toISOString();
    emit();
  }

  function getStorage() {
    try { return config.storage || root.localStorage || null; } catch (_) { return null; }
  }

  function parseValue(raw) {
    if (raw === null) return { present: false, value: null, encoding: null };
    try {
      return { present: true, value: JSON.parse(raw), encoding: 'json' };
    } catch (_) {
      return { present: true, value: raw, encoding: 'text' };
    }
  }

  function encodeValue(value) {
    if (typeof value === 'string') return value;
    return JSON.stringify(value);
  }

  function configure(options) {
    if (state.configured) throw new Error('AppV2Bridge can only be configured once.');
    options = options || {};
    config.supabaseUrl = String(options.supabaseUrl || '').replace(/\/+$/, '');
    config.supabaseAnonKey = String(options.supabaseAnonKey || '');
    config.supabaseClient = options.supabaseClient || null;
    config.supabaseFactory = options.supabaseFactory || null;
    config.storage = options.storage || null;
    config.onStatus = typeof options.onStatus === 'function' ? options.onStatus : null;
    if (!config.supabaseClient && (!config.supabaseUrl || !config.supabaseAnonKey)) {
      throw new Error('A Supabase client or public URL/key is required.');
    }
    if (!root.AppV2) throw new Error('Load app_v2.js before configuring AppV2Bridge.');
    root.AppV2.configure({
      supabaseClient: config.supabaseClient,
      supabaseUrl: config.supabaseUrl,
      supabaseAnonKey: config.supabaseAnonKey,
      supabaseFactory: config.supabaseFactory
    });
    state.configured = true;
    return api;
  }

  async function probe() {
    if (!state.configured) throw new Error('Configure AppV2Bridge before probing the backend.');
    setStatus('checking', null);
    const gate = await root.AppV2.checkCapability();
    if (!gate.ready) {
      setStatus('legacy-active', gate.reason || 'migration-not-ready');
      return { ready: false, reason: state.reason };
    }
    setStatus('v2-ready', null);
    return { ready: true, reason: null };
  }

  function collectLegacyBrowserState() {
    const storage = getStorage();
    if (!storage) throw new Error('Browser storage is unavailable.');
    const payload = {
      format: 'cardapiocerto-legacy-cache-v1',
      captured_at: new Date().toISOString(),
      values: {}
    };
    LOGICAL_KEYS.forEach(function (key) {
      const parsed = parseValue(storage.getItem(key));
      if (parsed.present) payload.values[key] = parsed.value;
    });
    return payload;
  }

  async function captureLegacyBrowserState() {
    if (state.status !== 'v2-ready') throw new Error('The V2 backend is not ready.');
    const snapshot = collectLegacyBrowserState();
    const response = await root.AppV2.captureLegacyBrowserState(snapshot, 'legacy-browser-cache-v1');
    state.lastCaptureAt = new Date().toISOString();
    emit();
    return response;
  }

  function hydrateConfirmedState(serverState, storageOverride) {
    if (!serverState || typeof serverState !== 'object' || Array.isArray(serverState)) {
      throw new Error('A server state object is required.');
    }
    const storage = storageOverride || getStorage();
    if (!storage || typeof storage.setItem !== 'function') {
      throw new Error('Browser storage is unavailable.');
    }
    const changed = [];
    LOGICAL_KEYS.forEach(function (key) {
      if (!Object.prototype.hasOwnProperty.call(serverState, key)) return;
      storage.setItem(key, encodeValue(serverState[key]));
      changed.push(key);
    });
    state.lastHydrationAt = new Date().toISOString();
    emit();
    return changed;
  }

  function getStatus() {
    return {
      configured: state.configured,
      status: state.status,
      reason: state.reason,
      lastProbeAt: state.lastProbeAt,
      lastCaptureAt: state.lastCaptureAt,
      lastHydrationAt: state.lastHydrationAt,
      logicalKeys: LOGICAL_KEYS.slice()
    };
  }

  function onStatus(listener) {
    if (typeof listener !== 'function') throw new Error('A listener function is required.');
    state.listeners.add(listener);
    return function () { state.listeners.delete(listener); };
  }

  const api = Object.freeze({
    configure,
    probe,
    collectLegacyBrowserState,
    captureLegacyBrowserState,
    hydrateConfirmedState,
    getStatus,
    onStatus
  });

  Object.defineProperty(root, 'AppV2Bridge', {
    value: api,
    enumerable: true,
    configurable: false,
    writable: false
  });
})(window);
