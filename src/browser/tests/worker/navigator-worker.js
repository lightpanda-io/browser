// Exposes WorkerNavigator (navigator) inside a WorkerGlobalScope.
// Replies with either { ok: true, results: {...} } or { ok: false, err }.
onmessage = async function(event) {
  try {
    // Permissions (transitively reachable: navigator.permissions -> Permissions
    // -> PermissionStatus). Must not depend on a Frame.
    const status = await navigator.permissions.query({ name: 'geolocation' });

    // StorageManager (navigator.storage -> StorageManager -> StorageEstimate).
    const estimate = await navigator.storage.estimate();

    // NavigatorUAData (navigator.userAgentData -> getHighEntropyValues()).
    const ua = navigator.userAgentData;
    const high_entropy = ua ? await ua.getHighEntropyValues(['architecture']) : null;

    const results = {
      has_navigator: typeof navigator !== 'undefined',
      // userAgent must match the value the page sees (passed in via postMessage).
      user_agent: navigator.userAgent,
      user_agent_matches_page: navigator.userAgent === event.data.pageUserAgent,
      app_name: navigator.appName,
      platform: navigator.platform,
      on_line: navigator.onLine,
      // SameObject: navigator should be stable across reads.
      identity_stable: navigator === navigator,

      // Permissions
      permission_name: status.name,
      permission_state: status.state,

      // StorageManager
      storage_quota: estimate.quota,
      storage_usage: estimate.usage,

      // NavigatorUAData
      has_ua_data: ua != null,
      ua_high_entropy_arch: high_entropy ? high_entropy.architecture : null,

      // [Exposed=Window] members must NOT leak into the worker realm.
      no_plugins: navigator.plugins === undefined,
      no_register_protocol_handler: navigator.registerProtocolHandler === undefined,
      no_model_context: navigator.modelContext === undefined,
    };
    postMessage({ ok: true, results });
  } catch (e) {
    postMessage({ ok: false, err: e.message });
  }
};
