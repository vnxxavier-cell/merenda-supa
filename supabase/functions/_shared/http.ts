import { AppError, logServerError } from "./errors.ts";

const PRODUCTION_ORIGIN = "https://cardapiocerto.vercel.app";
const ALLOWED_HEADERS = "authorization, apikey, content-type, x-client-info";

interface HttpResult {
  body: unknown;
  status?: number;
  headers?: HeadersInit;
}

interface HandlerOptions {
  methods: readonly string[];
  scope: string;
}

interface RequestContext {
  requestId: string;
}

type JsonHandler = (context: RequestContext) => Promise<HttpResult> | HttpResult;

function isAllowedOrigin(origin: string): boolean {
  if (origin === PRODUCTION_ORIGIN) return true;

  try {
    const url = new URL(origin);
    const loopback = url.hostname === "localhost" ||
      url.hostname === "127.0.0.1" ||
      url.hostname === "[::1]" ||
      url.hostname === "::1";
    return loopback && (url.protocol === "http:" || url.protocol === "https:");
  } catch {
    return false;
  }
}

function responseHeaders(
  request: Request,
  requestId: string,
  methods: readonly string[],
): Headers {
  const headers = new Headers({
    "cache-control": "no-store",
    "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    "content-type": "application/json; charset=utf-8",
    "referrer-policy": "no-referrer",
    "vary": "Origin",
    "x-content-type-options": "nosniff",
    "x-request-id": requestId,
  });
  const origin = request.headers.get("origin");
  if (origin && isAllowedOrigin(origin)) {
    headers.set("access-control-allow-origin", origin);
    headers.set("access-control-allow-headers", ALLOWED_HEADERS);
    headers.set("access-control-allow-methods", [...methods, "OPTIONS"].join(", "));
    headers.set("access-control-expose-headers", "x-request-id");
    headers.set("access-control-max-age", "600");
  }
  return headers;
}

function jsonResponse(
  request: Request,
  requestId: string,
  methods: readonly string[],
  body: unknown,
  status: number,
  extraHeaders?: HeadersInit,
): Response {
  const headers = responseHeaders(request, requestId, methods);
  if (extraHeaders) {
    new Headers(extraHeaders).forEach((value, key) => headers.set(key, value));
  }
  return new Response(JSON.stringify(body), { status, headers });
}

export async function handleHttpRequest(
  request: Request,
  options: HandlerOptions,
  handler: JsonHandler,
): Promise<Response> {
  const requestId = crypto.randomUUID();
  const methods = options.methods.map((method) => method.toUpperCase());
  const origin = request.headers.get("origin");

  if (origin && !isAllowedOrigin(origin)) {
    return jsonResponse(
      request,
      requestId,
      methods,
      { error: { code: "origin_not_allowed", message: "Request not allowed." } },
      403,
    );
  }

  if (request.method === "OPTIONS") {
    const headers = responseHeaders(request, requestId, methods);
    headers.delete("content-type");
    return new Response(null, { status: 204, headers });
  }

  if (!methods.includes(request.method.toUpperCase())) {
    return jsonResponse(
      request,
      requestId,
      methods,
      { error: { code: "method_not_allowed", message: "Method not allowed." } },
      405,
      { allow: [...methods, "OPTIONS"].join(", ") },
    );
  }

  try {
    const result = await handler({ requestId });
    return jsonResponse(
      request,
      requestId,
      methods,
      result.body,
      result.status ?? 200,
      result.headers,
    );
  } catch (error) {
    const appError = error instanceof AppError
      ? error
      : new AppError(500, "unexpected_error", "The request could not be completed.");
    if (appError.status >= 500) logServerError(options.scope, requestId, appError);
    return jsonResponse(
      request,
      requestId,
      methods,
      { error: { code: appError.code, message: appError.publicMessage } },
      appError.status,
    );
  }
}
