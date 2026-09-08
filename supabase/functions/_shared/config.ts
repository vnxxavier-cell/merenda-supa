import { internalError } from "./errors.ts";

export interface RuntimeConfig {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
}

let cachedConfig: RuntimeConfig | undefined;

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw internalError(`missing_env_${name.toLowerCase()}`);
  return value;
}

export function getRuntimeConfig(): RuntimeConfig {
  if (cachedConfig) return cachedConfig;

  const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/$/, "");
  const anonKey = requiredEnv("SUPABASE_ANON_KEY");
  const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(supabaseUrl);
  } catch {
    throw internalError("invalid_supabase_url");
  }

  if (parsedUrl.protocol !== "https:" && parsedUrl.hostname !== "localhost") {
    throw internalError("invalid_supabase_url_protocol");
  }
  if (anonKey === serviceRoleKey) throw internalError("invalid_supabase_keys");

  cachedConfig = Object.freeze({ supabaseUrl, anonKey, serviceRoleKey });
  return cachedConfig;
}
