import { type User } from "./deps.ts";
import { AppError, internalError } from "./errors.ts";
import {
  parseSessionDecision,
  type ProfileRecord,
  type SessionDecision,
} from "./contracts.ts";
import { type AppRole, isJsonObject, requireUuid } from "./validation.ts";
import {
  callServiceRpc,
  createAnonClient,
  signOutAccessToken,
} from "./supabase.ts";

export interface VerifiedSessionToken {
  accessToken: string;
  user: User;
  sessionId: string;
  issuedAt: number | null;
  expiresAt: number;
  claims: Record<string, unknown>;
}

export interface ActiveSessionContext extends VerifiedSessionToken {
  profile: ProfileRecord;
}

function extractBearerToken(request: Request): string {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(authorization);
  if (!match || match[1].length > 16_384) {
    throw new AppError(401, "unauthorized", "Authentication required.");
  }
  return match[1];
}

function decodeJwtPayload(token: string): Record<string, unknown> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new AppError(401, "unauthorized", "Authentication required.");

  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
    const payload: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (!isJsonObject(payload)) throw new Error("invalid payload");
    return payload;
  } catch {
    throw new AppError(401, "unauthorized", "Authentication required.");
  }
}

export async function verifyAccessToken(accessToken: string): Promise<VerifiedSessionToken> {
  const claims = decodeJwtPayload(accessToken);
  const { data, error } = await createAnonClient().auth.getUser(accessToken);
  if (error || !data.user) {
    throw new AppError(401, "unauthorized", "Authentication required.");
  }

  if (claims.sub !== data.user.id) {
    throw new AppError(401, "unauthorized", "Authentication required.");
  }
  const expiration = claims.exp;
  if (typeof expiration !== "number" || expiration * 1000 <= Date.now()) {
    throw new AppError(401, "unauthorized", "Authentication required.");
  }

  let sessionId: string;
  try {
    sessionId = requireUuid(claims.session_id, "session_id");
  } catch {
    throw new AppError(401, "unauthorized", "Authentication required.");
  }

  return {
    accessToken,
    user: data.user,
    sessionId,
    issuedAt: typeof claims.iat === "number" ? claims.iat : null,
    expiresAt: expiration,
    claims,
  };
}

export function verifyBearerRequest(request: Request): Promise<VerifiedSessionToken> {
  return verifyAccessToken(extractBearerToken(request));
}

export async function authorizeVerifiedSession(
  verified: VerifiedSessionToken,
  requiredRole: AppRole | null = null,
): Promise<SessionDecision> {
  const value = await callServiceRpc("edge_session_authorize", {
    p_auth_user_id: verified.user.id,
    p_auth_session_id: verified.sessionId,
    p_required_role: requiredRole,
  });
  const decision = parseSessionDecision(value);
  if (
    decision.profile?.authUserId &&
    decision.profile.authUserId.toLowerCase() !== verified.user.id.toLowerCase()
  ) {
    throw internalError("session_profile_mismatch");
  }
  return decision;
}

export async function requireActiveSession(
  request: Request,
  requiredRole: AppRole | null = null,
): Promise<ActiveSessionContext> {
  const verified = await verifyBearerRequest(request);
  const decision = await authorizeVerifiedSession(verified, requiredRole);
  if (!decision.allowed || !decision.active || !decision.newest || !decision.profile) {
    const forbidden = requiredRole !== null && decision.reason === "role";
    throw new AppError(
      forbidden ? 403 : 401,
      forbidden ? "forbidden" : "session_inactive",
      forbidden ? "Access denied." : "Authentication required.",
    );
  }
  if (requiredRole && decision.profile.role !== requiredRole) {
    throw new AppError(403, "forbidden", "Access denied.");
  }
  return { ...verified, profile: decision.profile };
}

export async function activateVerifiedSession(
  verified: VerifiedSessionToken,
  clientLabel?: string,
): Promise<ProfileRecord> {
  const value = await callServiceRpc("edge_session_activate", {
    p_auth_user_id: verified.user.id,
    p_session_id: verified.sessionId,
    p_expires_at: new Date(verified.expiresAt * 1000).toISOString(),
    p_client_label: clientLabel?.slice(0, 200) || null,
  });
  const decision = parseSessionDecision(value);
  if (!decision.allowed || !decision.active || !decision.newest || !decision.profile) {
    throw new AppError(401, "session_inactive", "Authentication required.");
  }
  if (decision.profile.authUserId?.toLowerCase() !== verified.user.id.toLowerCase()) {
    throw internalError("session_profile_mismatch");
  }
  return decision.profile;
}

export async function revokeVerifiedSession(verified: VerifiedSessionToken): Promise<void> {
  await Promise.allSettled([
    callServiceRpc("edge_session_revoke", {
      p_auth_user_id: verified.user.id,
      p_auth_session_id: verified.sessionId,
    }),
    signOutAccessToken(verified.accessToken),
  ]);
}
