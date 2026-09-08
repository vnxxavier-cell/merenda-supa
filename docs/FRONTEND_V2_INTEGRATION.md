# Frontend V2 Integration

`app_v2.js` is a server-first client API. `app_v2_bridge.js` is a transition
adapter. Neither script changes the legacy UI until explicitly configured and
the server capability gate reports ready.

## Safe inclusion

After the files are deployed, these inert scripts can be included after the
Supabase browser SDK:

```html
<script src="app_v2.js" defer></script>
<script src="app_v2_bridge.js" defer></script>
```

They do not replace login or storage behavior merely by being loaded.

## Required V2 flow

1. Configure `AppV2` with the public Supabase URL/key or browser client.
2. Call `AppV2.bootstrap()`.
3. Use `AppV2.signInWithPassword(username, password)` for traditional login.
4. Use `AppV2.signInWithGoogle()`; a new Google identity is registered as a
   pending access request and receives no application access. Listen to the
   `google-pending` event to show the approval message.
5. An administrator approves or rejects the request in the "Aprovações Google"
   panel of the admin page (explicit Aprovar/Recusar actions).
6. After server confirmation, use `AppV2.loadSchoolState()`.
7. Save with `AppV2.saveSchoolState(state, { expectedRevision })`.
8. Treat `conflict: true` and thrown network errors as unsaved changes.
9. Update the visible UI only from returned server state.

`AppV2` writes local cache only after a successful server response. It never
uploads an arbitrary localStorage snapshot as current state.

## Admin actions

```javascript
AppV2.adminUsers.googleRequests({ includeResolved: false });
AppV2.adminUsers.approveGoogle({
  auth_user_id, login, display_name, role, expires_at
});
AppV2.adminUsers.rejectGoogle(authUserId);
AppV2.adminUsers.verifyFrontendV2(deploymentReference);
```

## Legacy cache capture

Before removing legacy storage support, run the controlled one-time capture for
each profile that may hold local-only settings:

```javascript
AppV2Bridge.configure({
  supabaseUrl: 'https://YOUR_PROJECT_REF.supabase.co',
  supabaseAnonKey: 'YOUR_PUBLISHABLE_KEY'
});

await AppV2Bridge.probe();
await AppV2Bridge.captureLegacyBrowserState();
```

The capture is stored server-side as recovery evidence. It is not an automatic
overwrite of the canonical school document.

## Status UI

Attach visible status handlers before enabling V2 UI:

```javascript
AppV2.on('connection', updateConnectionIndicator);
AppV2.on('save', updateSaveIndicator);
AppV2.on('invalid-session', showSessionReplacedMessage);
AppV2.on('google-pending', showGoogleApprovalMessage);
AppV2.on('school-state', renderFromServerState);
```

The old `localStorage` proxy, `forceFullSync()` and SHA-256 browser login must
not be removed until this V2 path is tested against staging and the final RLS
cutover is ready.
