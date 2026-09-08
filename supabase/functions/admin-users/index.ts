import { requireActiveSession, type ActiveSessionContext } from "../_shared/auth.ts";
import {
  parseAdminProfilePage,
  parseProfile,
  profileResponse,
  type ProfileRecord,
} from "../_shared/contracts.ts";
import { type User } from "../_shared/deps.ts";
import { AppError, internalError } from "../_shared/errors.ts";
import { handleHttpRequest } from "../_shared/http.ts";
import { callServiceRpc, getServiceClient } from "../_shared/supabase.ts";
import {
  assertOnlyKeys,
  isJsonObject,
  normalizeEmail,
  optionalBoolean,
  optionalEmail,
  optionalIsoDate,
  optionalString,
  parseRole,
  readJsonObject,
  requiredSecret,
  requiredString,
  requireUuid,
  type JsonObject,
} from "../_shared/validation.ts";

const LONG_BAN = "876000h";

function authUserResponse(user: User | null): Record<string, unknown> | null {
  if (!user) return null;
  const providers = Array.isArray(user.app_metadata?.providers)
    ? user.app_metadata.providers.filter((value): value is string => typeof value === "string")
    : [];
  return {
    id: user.id,
    email: user.email ?? null,
    emailConfirmed: Boolean(user.email_confirmed_at),
    createdAt: user.created_at,
    lastSignInAt: user.last_sign_in_at ?? null,
    bannedUntil: user.banned_until ?? null,
    providers,
  };
}

async function getAuthUser(authUserId: string | null): Promise<User | null> {
  if (!authUserId) return null;
  const { data, error } = await getServiceClient().auth.admin.getUserById(
    requireUuid(authUserId, "auth_user_id"),
  );
  return error ? null : data.user;
}

function response(profile: ProfileRecord, authUser: User | null): Record<string, unknown> {
  return {
    ...profileResponse(profile, true) as Record<string, unknown>,
    auth: authUserResponse(authUser),
  };
}

async function serviceProfile(
  actor: ActiveSessionContext,
  profileId: string,
): Promise<ProfileRecord> {
  const raw = await callServiceRpc("edge_admin_profile_get", {
    p_actor_auth_user_id: actor.user.id,
    p_actor_session_id: actor.sessionId,
    p_profile_id: requireUuid(profileId, "profile_id"),
  });
  if (raw === null || raw === undefined) {
    throw new AppError(404, "user_not_found", "User not found.");
  }
  return parseProfile(raw);
}

function parseActionEnvelope(body: JsonObject): { action: string; payload: JsonObject } {
  assertOnlyKeys(body, ["action", "payload"]);
  const action = requiredString(body, "action", 64);
  if (!isJsonObject(body.payload)) {
    throw new AppError(400, "invalid_request", "payload must be an object.");
  }
  return { action, payload: body.payload };
}

async function listUsers(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["page", "perPage", "query", "includeInactive"]);
  const page = typeof payload.page === "number" && Number.isInteger(payload.page) && payload.page > 0
    ? payload.page
    : 1;
  const perPage = typeof payload.perPage === "number" && Number.isInteger(payload.perPage) &&
      payload.perPage > 0 && payload.perPage <= 100
    ? payload.perPage
    : 50;
  const query = optionalString(payload, "query", 100) ?? null;
  const includeInactive = optionalBoolean(payload, "includeInactive");
  const raw = await callServiceRpc("edge_admin_profiles_list", {
    p_actor_auth_user_id: actor.user.id,
    p_actor_session_id: actor.sessionId,
    p_limit: perPage,
    p_offset: (page - 1) * perPage,
    p_query: query,
    p_include_inactive: includeInactive !== false,
  });
  const result = parseAdminProfilePage(raw);
  const authUsers = await Promise.all(result.items.map((profile) => getAuthUser(profile.authUserId)));
  return {
    users: result.items.map((profile, index) => response(profile, authUsers[index])),
    pagination: {
      page,
      perPage,
      total: result.total,
      totalPages: Math.ceil(result.total / perPage),
    },
  };
}

async function getUser(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["user_id"]);
  const profile = await serviceProfile(actor, requiredString(payload, "user_id", 128));
  return { user: response(profile, await getAuthUser(profile.authUserId)) };
}

async function createUser(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["user"]);
  if (!isJsonObject(payload.user)) {
    throw new AppError(400, "invalid_request", "user must be an object.");
  }
  const user = payload.user;
  assertOnlyKeys(user, ["email", "password", "login", "name", "role", "expiresAt", "googleEmail"]);
  const email = normalizeEmail(user.email);
  const password = requiredSecret(user, "password", 8, 1024);
  const login = requiredString(user, "login", 128);
  const name = requiredString(user, "name", 200);
  const role = user.role === undefined ? "escola" : parseRole(user.role);
  const expiresAt = optionalIsoDate(user, "expiresAt") ?? null;
  const googleEmail = optionalEmail(user, "googleEmail") ?? null;

  const { data, error } = await getServiceClient().auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error || !data.user) {
    throw new AppError(409, "user_create_failed", "Unable to create user.");
  }

  try {
    const raw = await callServiceRpc("edge_admin_profile_create", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_target_auth_user_id: data.user.id,
      p_auth_email: email,
      p_login: login,
      p_display_name: name,
      p_role: role,
      p_expires_at: expiresAt,
      p_google_email: googleEmail,
    });
    const profile = parseProfile(raw);
    if (profile.authUserId?.toLowerCase() !== data.user.id.toLowerCase()) {
      throw internalError("admin_profile_mapping_mismatch");
    }
    return { user: response(profile, data.user) };
  } catch (cause) {
    // The Auth user was just created and no application data was attached yet.
    await getServiceClient().auth.admin.deleteUser(data.user.id, false).catch(() => undefined);
    throw cause;
  }
}

function parseExpectedRevision(value: unknown): number | null {
  if (value === undefined || value === null) return null;
  if (!Number.isInteger(value) || (value as number) < 1) {
    throw new AppError(400, "invalid_request", "expected_revision is invalid.");
  }
  return value as number;
}

async function updateUser(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["user_id", "changes", "expected_revision"]);
  const profileId = requireUuid(requiredString(payload, "user_id", 128), "user_id");
  if (!isJsonObject(payload.changes) || Object.keys(payload.changes).length === 0) {
    throw new AppError(400, "invalid_request", "changes must be a non-empty object.");
  }
  const changes = payload.changes;
  assertOnlyKeys(changes, ["email", "password", "login", "name", "role", "active", "expiresAt", "googleEmail"]);
  const expectedRevision = parseExpectedRevision(payload.expected_revision);
  const existing = await serviceProfile(actor, profileId);

  const profileChanges: Record<string, unknown> = {};
  if (changes.login !== undefined) profileChanges.login = requiredString(changes, "login", 128);
  if (changes.name !== undefined) profileChanges.display_name = requiredString(changes, "name", 200);
  if (changes.role !== undefined) profileChanges.role = parseRole(changes.role);
  if (changes.active !== undefined) profileChanges.active = optionalBoolean(changes, "active");
  if (changes.expiresAt !== undefined) profileChanges.expires_at = optionalIsoDate(changes, "expiresAt");
  if (changes.googleEmail !== undefined) profileChanges.google_email = optionalEmail(changes, "googleEmail");

  const authChanges: { email?: string; email_confirm?: boolean; password?: string } = {};
  if (changes.email !== undefined) {
    authChanges.email = normalizeEmail(changes.email);
    authChanges.email_confirm = true;
    profileChanges.auth_email = authChanges.email;
  }
  if (changes.password !== undefined) authChanges.password = requiredSecret(changes, "password", 8, 1024);
  if (Object.keys(authChanges).length) {
    if (!existing.authUserId) throw new AppError(409, "auth_user_missing", "User Auth migration is incomplete.");
    const { error } = await getServiceClient().auth.admin.updateUserById(
      requireUuid(existing.authUserId, "auth_user_id"),
      authChanges,
    );
    if (error) throw new AppError(409, "auth_update_failed", "Unable to update user.");
  }

  const raw = await callServiceRpc("edge_admin_profile_update", {
    p_actor_auth_user_id: actor.user.id,
    p_actor_session_id: actor.sessionId,
    p_profile_id: profileId,
    p_changes: profileChanges,
    p_expected_revision: expectedRevision,
  });
  const profile = parseProfile(raw);
  if (profile.active === false && profile.authUserId) {
    const { error } = await getServiceClient().auth.admin.updateUserById(
      requireUuid(profile.authUserId, "auth_user_id"),
      { ban_duration: LONG_BAN },
    );
    if (error) throw new AppError(502, "auth_deactivation_incomplete", "User was disabled but Auth ban must be retried.");
  }
  if (profile.active === true && changes.active === true && profile.authUserId) {
    const { error } = await getServiceClient().auth.admin.updateUserById(
      requireUuid(profile.authUserId, "auth_user_id"),
      { ban_duration: "none" },
    );
    if (error) throw new AppError(502, "auth_reactivation_failed", "Unable to reactivate user.");
  }
  return { user: response(profile, await getAuthUser(profile.authUserId)) };
}

async function setActive(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["user_id", "active", "expected_revision"]);
  const active = optionalBoolean(payload, "active");
  if (active === undefined) throw new AppError(400, "invalid_request", "active is required.");
  return updateUser(actor, {
    user_id: requiredString(payload, "user_id", 128),
    expected_revision: payload.expected_revision,
    changes: { active },
  });
}

async function softDelete(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["user_id", "expected_revision"]);
  return setActive(actor, {
    user_id: requiredString(payload, "user_id", 128),
    active: false,
    expected_revision: payload.expected_revision,
  });
}

async function cutoverReadiness(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, []);
  return {
    readiness: await callServiceRpc("edge_auth_cutover_readiness", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
    }),
  };
}

async function approveCutover(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["backup_reference"]);
  return {
    readiness: await callServiceRpc("edge_auth_cutover_approve", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_backup_reference: requiredString(payload, "backup_reference", 500),
    }),
  };
}

async function assignLegacyTechnicalSheets(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["legacy_fichas_custom_id", "owner_id", "school_id", "name", "notes"]);
  if (!Number.isInteger(payload.legacy_fichas_custom_id) || (payload.legacy_fichas_custom_id as number) < 0) {
    throw new AppError(400, "invalid_request", "legacy_fichas_custom_id is invalid.");
  }
  const notes = optionalString(payload, "notes", 500) ?? null;
  return {
    assignment: await callServiceRpc("edge_admin_assign_legacy_fichas", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_legacy_fichas_custom_id: payload.legacy_fichas_custom_id,
      p_owner_id: requireUuid(payload.owner_id, "owner_id"),
      p_school_id: requireUuid(payload.school_id, "school_id"),
      p_name: requiredString(payload, "name", 200),
      p_notes: notes,
    }),
  };
}

async function listGoogleRequests(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["include_resolved"]);
  const includeResolved = optionalBoolean(payload, "include_resolved") === true;
  return {
    requests: await callServiceRpc("edge_admin_google_requests_list", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_include_resolved: includeResolved,
    }),
  };
}

async function approveGoogleRequest(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["auth_user_id", "login", "display_name", "role", "expires_at", "note"]);
  const expiresAt = optionalIsoDate(payload, "expires_at") ?? null;
  const note = optionalString(payload, "note", 500) ?? null;
  const role = payload.role === undefined ? "escola" : parseRole(payload.role);
  return {
    profile: await callServiceRpc("edge_admin_google_request_approve", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_request_auth_user_id: requireUuid(payload.auth_user_id, "auth_user_id"),
      p_login: requiredString(payload, "login", 128),
      p_display_name: requiredString(payload, "display_name", 200),
      p_role: role,
      p_expires_at: expiresAt,
      p_note: note,
    }),
  };
}

async function rejectGoogleRequest(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["auth_user_id", "note"]);
  const note = optionalString(payload, "note", 500) ?? null;
  return {
    rejected: await callServiceRpc("edge_admin_google_request_reject", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_request_auth_user_id: requireUuid(payload.auth_user_id, "auth_user_id"),
      p_note: note,
    }),
  };
}

async function verifyFrontendV2(actor: ActiveSessionContext, payload: JsonObject) {
  assertOnlyKeys(payload, ["deployment_reference"]);
  return {
    verified: await callServiceRpc("edge_frontend_v2_verify", {
      p_actor_auth_user_id: actor.user.id,
      p_actor_session_id: actor.sessionId,
      p_deployment_reference: requiredString(payload, "deployment_reference", 500),
    }),
  };
}

Deno.serve((request) =>
  handleHttpRequest(
    request,
    { methods: ["POST"], scope: "admin-users" },
    async () => {
      const actor = await requireActiveSession(request, "admin");
      const envelope = parseActionEnvelope(await readJsonObject(request));
      let body: Record<string, unknown>;
      switch (envelope.action) {
        case "list":
          body = await listUsers(actor, envelope.payload);
          break;
        case "get":
          body = await getUser(actor, envelope.payload);
          break;
        case "create":
          body = await createUser(actor, envelope.payload);
          break;
        case "update":
          body = await updateUser(actor, envelope.payload);
          break;
        case "set-active":
          body = await setActive(actor, envelope.payload);
          break;
        case "delete":
          body = await softDelete(actor, envelope.payload);
          break;
        case "google-requests":
          body = await listGoogleRequests(actor, envelope.payload);
          break;
        case "google-approve":
          body = await approveGoogleRequest(actor, envelope.payload);
          break;
        case "google-reject":
          body = await rejectGoogleRequest(actor, envelope.payload);
          break;
        case "cutover-readiness":
          body = await cutoverReadiness(actor, envelope.payload);
          break;
        case "approve-cutover":
          body = await approveCutover(actor, envelope.payload);
          break;
        case "frontend-v2-verify":
          body = await verifyFrontendV2(actor, envelope.payload);
          break;
        case "assign-legacy-technical-sheets":
          body = await assignLegacyTechnicalSheets(actor, envelope.payload);
          break;
        default:
          throw new AppError(400, "invalid_request", "Unsupported action.");
      }
      return { body: { ok: true, ...body } };
    },
  )
);
