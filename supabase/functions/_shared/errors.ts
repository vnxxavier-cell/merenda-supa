export class AppError extends Error {
  readonly status: number;
  readonly code: string;
  readonly publicMessage: string;

  constructor(status: number, code: string, publicMessage: string) {
    super(code);
    this.name = "AppError";
    this.status = status;
    this.code = code;
    this.publicMessage = publicMessage;
  }
}

export function internalError(code: string): AppError {
  return new AppError(500, code, "The request could not be completed.");
}

export function logServerError(
  scope: string,
  requestId: string,
  error: unknown,
): void {
  const code = error instanceof AppError ? error.code : "unexpected_error";
  console.error(JSON.stringify({
    level: "error",
    scope,
    request_id: requestId,
    code,
  }));
}
