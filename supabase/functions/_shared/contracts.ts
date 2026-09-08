import { internalError } from "./errors.ts";
import { type AppRole, isJsonObject } from "./validation.ts";

export interface ProfileRecord {
  profileId: string;
  authUserId: string | null;
  dataOwnerId: string;
  login: string;
  name: string;
  role: AppRole;
  active: boolean;
  expiresAt: string | null;
  googleEmail: string | null;
  createdAt: string | null;
  updatedAt: string | null;
}

export interface SessionDecision {
  allowed: boolean;
  active: boolean;
  newest: boolean;
  reason: string | null;
  profile: ProfileRecord | null;
}

function stringField(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  if (typeof value !== "string" || !value) throw internalError("invalid_rpc_contract");
  return value;
}

function nullableStringField(
  record: Record<string, unknown>,
  key: string,
): string | null {
  const value = record[key];
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") throw internalError("invalid_rpc_contract");
  return value;
}

export function parseProfile(value: unknown): ProfileRecord {
  if (!isJsonObject(value)) throw internalError("invalid_rpc_contract");
  const role = value.role;
  if (role !== "admin" && role !== "escola") throw internalError("invalid_rpc_contract");
  if (typeof value.active !== "boolean") throw internalError("invalid_rpc_contract");

  return {
    profileId: stringField(value, "profile_id"),
    authUserId: nullableStringField(value, "auth_user_id"),
    dataOwnerId: stringField(value, "data_owner_id"),
    login: stringField(value, "login"),
    name: stringField(value, "display_name"),
    role,
    active: value.active,
    expiresAt: nullableStringField(value, "expires_at"),
    googleEmail: nullableStringField(value, "google_email"),
    createdAt: nullableStringField(value, "created_at"),
    updatedAt: nullableStringField(value, "updated_at"),
  };
}

export function profileResponse(profile: ProfileRecord, adminView = false): unknown {
  const response: Record<string, unknown> = {
    id: profile.profileId,
    authUserId: profile.authUserId,
    dataOwnerId: profile.dataOwnerId,
    login: profile.login,
    name: profile.name,
    role: profile.role,
    active: profile.active,
    expiresAt: profile.expiresAt,
  };
  if (adminView) {
    response.googleEmail = profile.googleEmail;
    response.createdAt = profile.createdAt;
    response.updatedAt = profile.updatedAt;
  }
  return response;
}

export function parseSessionDecision(value: unknown): SessionDecision {
  if (!isJsonObject(value)) throw internalError("invalid_rpc_contract");
  if (
    typeof value.allowed !== "boolean" || typeof value.active !== "boolean" ||
    typeof value.newest !== "boolean"
  ) {
    throw internalError("invalid_rpc_contract");
  }
  return {
    allowed: value.allowed,
    active: value.active,
    newest: value.newest,
    reason: nullableStringField(value, "reason"),
    profile: value.profile === null || value.profile === undefined
      ? null
      : parseProfile(value.profile),
  };
}

export interface LegacyVerification {
  legacyId: string;
  authUserId: string | null;
}

export function parseLegacyVerification(value: unknown): LegacyVerification | null {
  if (value === null || value === undefined) return null;
  if (!isJsonObject(value)) throw internalError("invalid_rpc_contract");
  return {
    legacyId: stringField(value, "legacy_id"),
    authUserId: nullableStringField(value, "auth_user_id"),
  };
}

export interface AdminProfilePage {
  items: ProfileRecord[];
  total: number;
}

export function parseAdminProfilePage(value: unknown): AdminProfilePage {
  if (!isJsonObject(value) || !Array.isArray(value.items)) {
    throw internalError("invalid_rpc_contract");
  }
  if (!Number.isSafeInteger(value.total) || Number(value.total) < 0) {
    throw internalError("invalid_rpc_contract");
  }
  return {
    items: value.items.map(parseProfile),
    total: Number(value.total),
  };
}
