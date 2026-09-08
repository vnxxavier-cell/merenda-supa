import {
  activateVerifiedSession,
  revokeVerifiedSession,
  verifyBearerRequest,
  type VerifiedSessionToken,
} from "../_shared/auth.ts";
import { parseProfile, profileResponse } from "../_shared/contracts.ts";
import { AppError, internalError } from "../_shared/errors.ts";
import { handleHttpRequest } from "../_shared/http.ts";
import { callServiceRpc } from "../_shared/supabase.ts";
import { isJsonObject, normalizeEmail } from "../_shared/validation.ts";

async function denyGoogleLogin(
  verified: VerifiedSessionToken,
  code = "google_login_not_authorized",
): Promise<never> {
  await revokeVerifiedSession(verified);
  throw new AppError(403, code, "Google account is not authorized.");
}

function isOauthSession(claims: Record<string, unknown>): boolean {
  return Array.isArray(claims.amr) && claims.amr.some((entry) =>
    isJsonObject(entry) && entry.method === "oauth"
  );
}

function identityName(identityData: Record<string, unknown>, verified: VerifiedSessionToken): string {
  const candidate = identityData.name ?? identityData.full_name;
  if (typeof candidate === "string" && candidate.trim()) return candidate.trim();
  const metadata = verified.user.user_metadata ?? {};
  const metaName = metadata.full_name ?? metadata.name;
  if (typeof metaName === "string" && metaName.trim()) return metaName.trim();
  return verified.user.email?.split("@")[0] ?? "Usuário Google";
}

Deno.serve((request) =>
  handleHttpRequest(
    request,
    { methods: ["POST"], scope: "claim-google-login" },
    async () => {
      const verified = await verifyBearerRequest(request);
      if (!isOauthSession(verified.claims) || verified.issuedAt === null) {
        return denyGoogleLogin(verified);
      }

      const googleIdentity = (verified.user.identities ?? []).find((identity) => {
        if (identity.provider !== "google") return false;
        const lastSignIn = Date.parse(identity.last_sign_in_at ?? "");
        return Number.isFinite(lastSignIn) &&
          lastSignIn >= (verified.issuedAt! - 300) * 1000 &&
          lastSignIn <= Date.now() + 60_000;
      });
      if (!googleIdentity || !verified.user.email_confirmed_at) {
        return denyGoogleLogin(verified);
      }

      const identityData = isJsonObject(googleIdentity.identity_data)
        ? googleIdentity.identity_data
        : {};
      const emailVerified = identityData.email_verified === true ||
        identityData.verified_email === true;
      if (!emailVerified) return denyGoogleLogin(verified);

      let googleEmail: string;
      try {
        googleEmail = normalizeEmail(identityData.email, "google_email");
      } catch {
        return denyGoogleLogin(verified);
      }

      const rawSubject = typeof identityData.sub === "string"
        ? identityData.sub
        : googleIdentity.id;
      const googleSubject = rawSubject.trim();
      if (!googleSubject || googleSubject.length > 255) return denyGoogleLogin(verified);

      const claimed = await callServiceRpc("edge_claim_google_login", {
        p_auth_user_id: verified.user.id,
        p_google_subject: googleSubject,
        p_google_email: googleEmail,
        p_display_name: identityName(identityData, verified),
      });
      if (claimed === null || claimed === undefined || !isJsonObject(claimed)) {
        return denyGoogleLogin(verified, "google_claim_failed");
      }

      const status = claimed.status;
      if (status === "pending") {
        // The Auth identity exists but has no application profile or school
        // access. The client shows an approval message and remains signed out.
        await revokeVerifiedSession(verified).catch(() => undefined);
        return {
          body: {
            ok: true,
            authorized: false,
            status: "pending",
            message: "Aguardando aprovação do administrador.",
          },
        };
      }

      if (status !== "approved" || !isJsonObject(claimed.profile)) {
        return denyGoogleLogin(verified, claimed.reason === "identity_already_registered"
          ? "google_identity_already_registered"
          : "google_login_not_authorized");
      }

      const claimedProfile = parseProfile(claimed.profile);
      if (claimedProfile.authUserId?.toLowerCase() !== verified.user.id.toLowerCase()) {
        await revokeVerifiedSession(verified);
        throw internalError("google_profile_mismatch");
      }

      let activeProfile;
      try {
        activeProfile = await activateVerifiedSession(
          verified,
          request.headers.get("user-agent") ?? undefined,
        );
      } catch (error) {
        await revokeVerifiedSession(verified);
        throw error;
      }
      if (activeProfile.profileId !== claimedProfile.profileId) {
        await revokeVerifiedSession(verified);
        throw internalError("google_profile_mismatch");
      }

      return {
        body: {
          ok: true,
          authorized: true,
          status: "approved",
          profile: profileResponse(activeProfile),
        },
      };
    },
  )
);
