import { createClient, type SupabaseClient } from "./deps.ts";
import { getRuntimeConfig } from "./config.ts";
import { internalError } from "./errors.ts";

const CLIENT_OPTIONS = {
  auth: {
    autoRefreshToken: false,
    detectSessionInUrl: false,
    persistSession: false,
  },
  global: {
    headers: { "x-client-info": "cardapiocerto-edge-functions/1.0" },
  },
} as const;

let serviceClient: SupabaseClient | undefined;

export function getServiceClient(): SupabaseClient {
  if (!serviceClient) {
    const config = getRuntimeConfig();
    serviceClient = createClient(
      config.supabaseUrl,
      config.serviceRoleKey,
      CLIENT_OPTIONS,
    );
  }
  return serviceClient;
}

export function createAnonClient(): SupabaseClient {
  const config = getRuntimeConfig();
  return createClient(config.supabaseUrl, config.anonKey, CLIENT_OPTIONS);
}

export async function callServiceRpc(
  functionName: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await getServiceClient().rpc(functionName, args);
  if (error) throw internalError(`rpc_${functionName}_failed`);
  return data;
}

export async function signOutAccessToken(accessToken: string): Promise<boolean> {
  const config = getRuntimeConfig();
  const endpoint = new URL("/auth/v1/logout", config.supabaseUrl);
  endpoint.searchParams.set("scope", "local");

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        apikey: config.anonKey,
        authorization: `Bearer ${accessToken}`,
      },
    });
    return response.ok;
  } catch {
    return false;
  }
}
