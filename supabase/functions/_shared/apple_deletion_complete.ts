import { readAppleDeletionBody } from "./apple_deletion_body.ts";
import {
  AccountDeletionHTTPError,
  AppleTokenExchange,
  continueAccountDeletion,
  DeleteAccountDependencies,
} from "../delete-account/index.ts";

export interface AppleDeletionClaim {
  authorizationCode: string;
  clientID: string;
  redirectURI: string;
  nonce: string;
}
export interface AppleDeletionWebCompleteDependencies {
  deletion: DeleteAccountDependencies;
  claim(
    authUserID: string,
    requestID: string,
    verifierDigest: string,
  ): Promise<AppleDeletionClaim | null>;
  webClient(): {
    clientID: string;
    redirectURI: string;
    exchange(code: string): Promise<AppleTokenExchange>;
  };
}
export async function appleDeletionWebCompleteHandler(
  request: Request,
  dependencies: AppleDeletionWebCompleteDependencies,
): Promise<Response> {
  const headers = {
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
  };
  const reject = (status: number) => new Response(null, { status, headers });
  if (request.method !== "POST") return reject(405);
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  if (!/^Bearer\s+\S+$/i.test(authorization)) return reject(401);
  let userID: string;
  try {
    userID = await dependencies.deletion.authenticate(authorization);
    if (!userID) return reject(401);
  } catch {
    return reject(401);
  }
  let requestID: string | null = null;
  let verifier = "";
  try {
    if (
      request.headers.get("content-type")?.split(";")[0].trim()
          .toLowerCase() !== "application/json" ||
      !request.body
    ) return reject(400);
    const bytes = await readAppleDeletionBody(request, 2048);
    const body = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(
        bytes,
      ),
    );
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return reject(400);
    }
    if (Object.keys(body).join(",") === "resume" && body.resume === true) {
      requestID = null;
    } else {
      if (
        Object.keys(body).sort().join(",") !== "claim_verifier,request_id" ||
        typeof body.request_id !== "string" ||
        !/^[0-9a-f]{64}$/.test(body.request_id) ||
        typeof body.claim_verifier !== "string" ||
        !/^[0-9a-f]{64}$/.test(body.claim_verifier)
      ) return reject(400);
      requestID = body.request_id;
      verifier = body.claim_verifier;
    }
  } catch {
    return reject(400);
  }
  return continueAccountDeletion(userID, dependencies.deletion, async () => {
    if (requestID === null) {
      throw new AccountDeletionHTTPError(401, "reauthentication_required");
    }
    // Resolve the trusted configuration before consuming a single-use grant.
    const client = dependencies.webClient();
    const digest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
    );
    const claim = await dependencies.claim(
      userID,
      requestID,
      [...digest].map((b) => b.toString(16).padStart(2, "0")).join(""),
    );
    if (
      !claim || claim.clientID !== client.clientID ||
      claim.redirectURI !== client.redirectURI ||
      !/^[0-9a-f]{64}$/.test(claim.nonce) ||
      !/^[\x21-\x7e]{16,4096}$/.test(claim.authorizationCode)
    ) {
      throw new AccountDeletionHTTPError(401, "reauthentication_required");
    }
    return {
      clientID: client.clientID,
      nonce: claim.nonce,
      tokens: await client.exchange(claim.authorizationCode),
    };
  });
}
