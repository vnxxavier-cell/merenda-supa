import { AppError } from "./errors.ts";

const MAX_BODY_BYTES = 32 * 1024;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CONTROL_PATTERN = /[\u0000-\u001f\u007f]/;

export type JsonObject = Record<string, unknown>;

export function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readJsonObject(request: Request): Promise<JsonObject> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new AppError(415, "unsupported_media_type", "Content-Type must be application/json.");
  }

  const declaredLength = Number(request.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    throw new AppError(413, "request_too_large", "Request body is too large.");
  }

  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    throw new AppError(413, "request_too_large", "Request body is too large.");
  }

  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new AppError(400, "invalid_json", "Request body must be valid JSON.");
  }
  if (!isJsonObject(value)) {
    throw new AppError(400, "invalid_request", "Request body must be a JSON object.");
  }
  return value;
}

export function assertOnlyKeys(body: JsonObject, allowed: readonly string[]): void {
  const allowedKeys = new Set(allowed);
  if (Object.keys(body).some((key) => !allowedKeys.has(key))) {
    throw new AppError(400, "invalid_request", "Request contains unsupported fields.");
  }
}

export function requiredString(
  body: JsonObject,
  key: string,
  maxLength: number,
): string {
  const value = body[key];
  if (typeof value !== "string") {
    throw new AppError(400, "invalid_request", `${key} is required.`);
  }
  const normalized = value.trim();
  if (!normalized || normalized.length > maxLength || CONTROL_PATTERN.test(normalized)) {
    throw new AppError(400, "invalid_request", `${key} is invalid.`);
  }
  return normalized;
}

export function optionalString(
  body: JsonObject,
  key: string,
  maxLength: number,
): string | undefined {
  if (!(key in body)) return undefined;
  return requiredString(body, key, maxLength);
}

export function requiredSecret(
  body: JsonObject,
  key: string,
  minLength: number,
  maxLength: number,
): string {
  const value = body[key];
  if (
    typeof value !== "string" || value.length < minLength ||
    value.length > maxLength || value.includes("\u0000")
  ) {
    throw new AppError(400, "invalid_request", `${key} is invalid.`);
  }
  return value;
}

export function optionalBoolean(body: JsonObject, key: string): boolean | undefined {
  if (!(key in body)) return undefined;
  if (typeof body[key] !== "boolean") {
    throw new AppError(400, "invalid_request", `${key} must be a boolean.`);
  }
  return body[key];
}

export function normalizeEmail(value: unknown, key = "email"): string {
  if (typeof value !== "string") {
    throw new AppError(400, "invalid_request", `${key} is required.`);
  }
  const email = value.trim().toLowerCase();
  if (
    !email || email.length > 254 || CONTROL_PATTERN.test(email) ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
  ) {
    throw new AppError(400, "invalid_request", `${key} is invalid.`);
  }
  return email;
}

export function optionalEmail(
  body: JsonObject,
  key: string,
): string | null | undefined {
  if (!(key in body)) return undefined;
  if (body[key] === null) return null;
  return normalizeEmail(body[key], key);
}

export type AppRole = "admin" | "escola";

export function parseRole(value: unknown, key = "role"): AppRole {
  if (value !== "admin" && value !== "escola") {
    throw new AppError(400, "invalid_request", `${key} is invalid.`);
  }
  return value;
}

export function optionalIsoDate(
  body: JsonObject,
  key: string,
): string | null | undefined {
  if (!(key in body)) return undefined;
  const value = body[key];
  if (value === null) return null;
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new AppError(400, "invalid_request", `${key} must use YYYY-MM-DD.`);
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new AppError(400, "invalid_request", `${key} is invalid.`);
  }
  return value;
}

export function requireUuid(value: unknown, key = "id"): string {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new AppError(400, "invalid_request", `${key} is invalid.`);
  }
  return value.toLowerCase();
}

export function positiveInteger(
  value: string | null,
  fallback: number,
  maximum: number,
): number {
  if (value === null || value === "") return fallback;
  if (!/^\d+$/.test(value)) {
    throw new AppError(400, "invalid_request", "Pagination is invalid.");
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maximum) {
    throw new AppError(400, "invalid_request", "Pagination is invalid.");
  }
  return parsed;
}
