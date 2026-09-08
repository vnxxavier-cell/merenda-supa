import {
  authorizeVerifiedSession,
  revokeVerifiedSession,
  verifyBearerRequest,
} from "../_shared/auth.ts";
import { profileResponse } from "../_shared/contracts.ts";
import { AppError } from "../_shared/errors.ts";
import { handleHttpRequest } from "../_shared/http.ts";

Deno.serve((request) =>
  handleHttpRequest(
    request,
    { methods: ["GET", "POST"], scope: "session-status" },
    async () => {
      try {
        const verified = await verifyBearerRequest(request);
        const decision = await authorizeVerifiedSession(verified);
        if (!decision.allowed || !decision.active || !decision.newest || !decision.profile) {
          await revokeVerifiedSession(verified);
          return {
            status: 401,
            body: { active: false, newest: false },
          };
        }
        return {
          body: {
            active: true,
            newest: true,
            profile: profileResponse(decision.profile),
          },
        };
      } catch (error) {
        if (error instanceof AppError && error.status < 500) {
          return {
            status: 401,
            body: { active: false, newest: false },
          };
        }
        throw error;
      }
    },
  )
);
