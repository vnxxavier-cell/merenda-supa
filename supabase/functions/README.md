# Edge Functions

## Required secrets

Set these in Supabase Edge Function secrets only:

```text
SUPABASE_URL
SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
```

Do not add a service role key to `index.html`, `app_v2.js`, Vercel variables
available to the browser, Git, logs or support messages.

## Functions

| Function | Purpose | Caller |
|---|---|---|
| `legacy-login` | First-login migration and normal username/password Auth sign-in | Anonymous browser request |
| `claim-google-login` | Confirms an approved Google identity or registers a pending approval request | Authenticated browser request |
| `session-status` | Verifies the active/current server session | Authenticated browser request |
| `admin-users` | Protected user management, Google approvals and cutover operations | Active administrator only |

All functions enforce the Vercel production origin and localhost development
origins in code. Platform JWT verification is disabled in `config.toml` so the
functions can return controlled CORS and migration errors; protected functions
verify bearer tokens internally against Supabase Auth and server session state.

## Google flow

1. The user signs in with Google through Supabase Auth.
2. `claim-google-login` validates the fresh, verified Google identity.
3. If an active profile already authorizes that identity, the session is
   activated normally.
4. Otherwise a **pending access request** is recorded with no profile, school
   membership or data access. The client remains signed out.
5. An administrator approves or rejects the request through `admin-users`.
6. After approval, the same Google account gains a profile, role and school.

## Deploy

```powershell
supabase functions deploy legacy-login --no-verify-jwt
supabase functions deploy claim-google-login --no-verify-jwt
supabase functions deploy session-status --no-verify-jwt
supabase functions deploy admin-users --no-verify-jwt
```

Deploy only after migrations `20260903000100` through `20260903000500` have
been applied to the intended staging or production project.
