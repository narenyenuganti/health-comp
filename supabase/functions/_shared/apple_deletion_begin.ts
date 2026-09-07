import { readAppleDeletionBody } from "./apple_deletion_body.ts";

export interface AppleDeletionWebConfiguration {
  clientID: string;
  projectURL: string;
}

export interface AppleDeletionWebBeginRecord {
  authUserID: string;
  requestID: string;
  stateDigest: string;
  verifierDigest: string;
  nonce: string;
  clientID: string;
  redirectURI: string;
}

export interface AppleDeletionWebBeginDependencies {
  authenticate(authorization: string): Promise<string>;
  configuration(): AppleDeletionWebConfiguration | null;
  begin(record: AppleDeletionWebBeginRecord): Promise<void>;
}

export async function appleDeletionWebBeginHandler(
  request: Request,
  dependencies: AppleDeletionWebBeginDependencies,
): Promise<Response> {
  const headers = {
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
  };
  const reject = (status: number) => new Response(null, { status, headers });
  if (request.method !== "POST") return reject(405);
  const authorization = request.headers.get("authorization")?.trim() ?? "";
  if (!/^Bearer\s+\S+$/i.test(authorization)) return reject(401);
  let authUserID: string;
  try {
    authUserID = await dependencies.authenticate(authorization);
    if (!authUserID) return reject(401);
  } catch {
    return reject(401);
  }
  let clientID: string;
  let redirectURI: string;
  try {
    const config = dependencies.configuration();
    if (!config || !/^[A-Za-z0-9.-]{1,255}$/.test(config.clientID)) {
      return reject(503);
    }
    const project = new URL(config.projectURL);
    if (
      project.protocol !== "https:" || project.username || project.password ||
      project.port || project.pathname !== "/" || project.search || project.hash
    ) return reject(503);
    clientID = config.clientID;
    redirectURI = `${project.origin}/functions/v1/apple-deletion-callback`;
  } catch {
    return reject(503);
  }
  let nonce: string;
  let verifier: string;
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
    if (
      !body || typeof body !== "object" || Array.isArray(body) ||
      Object.keys(body).sort().join(",") !== "claim_verifier,nonce" ||
      typeof body.claim_verifier !== "string" ||
      !/^[0-9a-f]{64}$/.test(body.claim_verifier) ||
      typeof body.nonce !== "string" || !/^[0-9a-f]{64}$/.test(body.nonce)
    ) return reject(400);
    verifier = body.claim_verifier;
    nonce = body.nonce;
  } catch {
    return reject(400);
  }
  try {
    const requestID = hex(crypto.getRandomValues(new Uint8Array(32)));
    const state = hex(crypto.getRandomValues(new Uint8Array(32)));
    const hash = async (value: string) =>
      hex(
        new Uint8Array(
          await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(value),
          ),
        ),
      );
    await dependencies.begin({
      authUserID,
      requestID,
      stateDigest: await hash(state),
      verifierDigest: await hash(verifier),
      nonce,
      clientID,
      redirectURI,
    });
    const url = new URL("https://appleid.apple.com/auth/authorize");
    url.search = new URLSearchParams({
      client_id: clientID,
      redirect_uri: redirectURI,
      response_type: "code",
      response_mode: "form_post",
      state,
      nonce,
    }).toString();
    return Response.json(
      { request_id: requestID, authorization_url: url.href },
      { headers },
    );
  } catch {
    return reject(503);
  }
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
