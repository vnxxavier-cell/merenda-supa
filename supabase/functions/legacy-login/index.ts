import {
  activateVerifiedSession,
  revokeVerifiedSession,
  verifyAccessToken,
} from "../_shared/auth.ts";
import {
  parseLegacyVerification,
  parseProfile,
  profileResponse,
  type ProfileRecord,
} from "../_shared/contracts.ts";
import { AppError, internalError } from "../_shared/errors.ts";
import { handleHttpRequest } from "../_shared/http.ts";
import {
  callServiceRpc,
  createAnonClient,
  getServiceClient,
} from "../_shared/supabase.ts";
import {
  assertOnlyKeys,
  readJsonObject,
  requiredSecret,
  requiredString,
  requireUuid,
} from "../_shared/validation.ts";

const LOGIN_FAILED = "Unable to sign in.";

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function resolveMigratedProfile(username: string): Promise<ProfileRecord | null> {
  const value = await callServiceRpc("edge_login_resolve", {
    p_username: username,
  });
  return value === null || value === undefined ? null : parseProfile(value);
}

async function getAuthEmail(authUserId: string): Promise<string> {
  const id = requireUuid(authUserId, "auth_user_id");
  const { data, error } = await getServiceClient().auth.admin.getUserById(id);
  if (error || !data.user?.email) throw internalError("legacy_auth_user_missing");
  return data.user.email;
}

async function rollbackNewAuthUser(authUserId: string): Promise<void> {
  await getServiceClient().auth.admin.deleteUser(authUserId, false).catch(() => undefined);
}

async function migrateLegacyUser(
  username: string,
  password: string,
): Promise<ProfileRecord> {
  const passwordSha256 = await sha256Hex(password);
  const verification = parseLegacyVerification(
    await callServiceRpc("edge_legacy_login_verify", {
      p_username: username,
      p_password_sha256: passwordSha256,
    }),
  );
  if (!verification) throw new AppError(401, "login_failed", LOGIN_FAILED);

  let authUserId = verification.authUserId;
  let authEmail: string;
  let createdAuthUser = false;

  if (authUserId) {
    authUserId = requireUuid(authUserId, "auth_user_id");
    authEmail = await getAuthEmail(authUserId);
    const { error } = await getServiceClient().auth.admin.updateUserById(authUserId, {
      password,
    });
    if (error) throw new AppError(401, "login_failed", LOGIN_FAILED);
  } else {
    const legacyAlias = await sha256Hex(`legacy-user:${verification.legacyId}`);
    authEmail = `legacy-${legacyAlias.slice(0, 48)}@cardapiocerto.invalid`;
    const { data, error } = await getServiceClient().auth.admin.createUser({
      email: authEmail,
      password,
      email_confirm: true,
    });

    if (error || !data.user) {
      const racedProfile = await resolveMigratedProfile(username).catch(() => null);
      if (!racedProfile?.authUserId) {
        throw new AppError(401, "login_failed", LOGIN_FAILED);
      }
      authUserId = requireUuid(racedProfile.authUserId, "auth_user_id");
      authEmail = await getAuthEmail(authUserId);
    } else {
      authUserId = data.user.id;
      createdAuthUser = true;
    }
  }

  let completedProfile: ProfileRecord;
  try {
    completedProfile = parseProfile(
      await callServiceRpc("edge_legacy_login_complete", {
        p_legacy_id: verification.legacyId,
        p_auth_user_id: authUserId,
        p_auth_email: authEmail,
      }),
    );
  } catch (error) {
    const racedProfile = await resolveMigratedProfile(username).catch(() => null);
    if (!racedProfile?.authUserId) {
      if (createdAuthUser) await rollbackNewAuthUser(authUserId);
      throw error;
    }
    completedProfile = racedProfile;
  }

  if (!completedProfile.authUserId) {
    if (createdAuthUser) await rollbackNewAuthUser(authUserId);
    throw internalError("legacy_mapping_incomplete");
  }

  const canonicalAuthUserId = requireUuid(completedProfile.authUserId, "auth_user_id");
  if (canonicalAuthUserId !== authUserId) {
    if (createdAuthUser) await rollbackNewAuthUser(authUserId);
    authEmail = await getAuthEmail(canonicalAuthUserId);
  }
  return completedProfile;
}

function sessionPayload(session: {
  access_token: string;
  refresh_token: string;
  expires_at?: number;
  expires_in: number;
  token_type: string;
}): Record<string, unknown> {
  return {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_at: session.expires_at ?? null,
    expires_in: session.expires_in,
    token_type: session.token_type,
  };
}

Deno.serve((request) =>
  handleHttpRequest(
    request,
    { methods: ["POST"], scope: "legacy-login" },
    async () => {
      const body = await readJsonObject(request);
      assertOnlyKeys(body, ["username", "password"]);
      const username = requiredString(body, "username", 128);
      const password = requiredSecret(body, "password", 1, 1024);

      let profile = await resolveMigratedProfile(username);
      if (!profile) profile = await migrateLegacyUser(username, password);
      if (!profile.authUserId) throw internalError("legacy_mapping_incomplete");

      const authUserId = requireUuid(profile.authUserId, "auth_user_id");
      const authEmail = await getAuthEmail(authUserId);
      const { data, error } = await createAnonClient().auth.signInWithPassword({
        email: authEmail,
        password,
      });
      if (error || !data.session || data.user.id !== authUserId) {
        throw new AppError(401, "login_failed", LOGIN_FAILED);
      }

      const verified = await verifyAccessToken(data.session.access_token);
      let activeProfile: ProfileRecord;
      try {
        activeProfile = await activateVerifiedSession(
          verified,
          request.headers.get("user-agent") ?? undefined,
        );
      } catch (error) {
        await revokeVerifiedSession(verified);
        if (error instanceof AppError && error.status >= 500) throw error;
        throw new AppError(401, "login_failed", LOGIN_FAILED);
      }

      if (activeProfile.profileId !== profile.profileId) {
        await revokeVerifiedSession(verified);
        throw internalError("legacy_profile_mismatch");
      }

        return {
          body: {
            ok: true,
            auth_user_id: authUserId,
            session: sessionPayload(data.session),
            profile: profileResponse(activeProfile),
        },
      };
    },
  )
);
