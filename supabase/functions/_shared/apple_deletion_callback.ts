import { readAppleDeletionBody } from "./apple_deletion_body.ts";

export type AppleDeletionCallback =
  | { kind: "authorized"; state: string; code: string }
  | { kind: "cancelled"; state: string };

export class AppleDeletionCallbackError extends Error {
  constructor() {
    super("invalid_apple_deletion_callback");
  }
}

export interface AppleDeletionCallbackStore {
  // Atomically validate a live request state and escrow its code (or cancel it).
  // Null means expired, unknown, or already consumed. Never return a profile ID.
  receive(
    callback: AppleDeletionCallback,
  ): Promise<{ requestID: string } | null>;
}

export async function appleDeletionCallbackHandler(
  request: Request,
  store: AppleDeletionCallbackStore,
): Promise<Response> {
  const headers = {
    "cache-control": "no-store",
    "referrer-policy": "no-referrer",
  };
  let callback: AppleDeletionCallback;
  try {
    callback = await readAppleDeletionCallback(request);
  } catch {
    return new Response(null, { status: 400, headers });
  }
  try {
    const result = await store.receive(callback);
    if (result === null) return new Response(null, { status: 400, headers });
    if (!/^[0-9a-f]{64}$/.test(result.requestID)) {
      return new Response(null, { status: 503, headers });
    }
    const destination = new URL(
      "healthcomp-staging-auth://apple/deletion-callback",
    );
    destination.searchParams.set("request_id", result.requestID);
    return new Response(null, {
      status: 303,
      headers: { ...headers, location: destination.href },
    });
  } catch {
    // Storage diagnostics can contain private context; return no body or URL.
    return new Response(null, { status: 503, headers });
  }
}

export async function readAppleDeletionCallback(
  request: Request,
): Promise<AppleDeletionCallback> {
  // Shape validation only. The store must separately verify live state,
  // expiry and single-use ownership before accepting or retaining any code.
  const type = request.headers.get("content-type")?.trim() ?? "";
  if (
    request.method !== "POST" || !request.body ||
    !/^application\/x-www-form-urlencoded(?:;\s*charset=utf-8)?$/i.test(type)
  ) {
    throw new AppleDeletionCallbackError();
  }
  let text: string;
  try {
    const bytes = await readAppleDeletionBody(request, 16_384);
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new AppleDeletionCallbackError();
  }
  if (/%(?![0-9a-f]{2})/i.test(text)) throw new AppleDeletionCallbackError();
  const fields = new URLSearchParams(text);
  const keys = [...fields.keys()].sort();
  const state = fields.get("state") ?? "";
  if (
    keys.length !== 2 || keys[1] !== "state" || !/^[0-9a-f]{64}$/.test(state)
  ) {
    throw new AppleDeletionCallbackError();
  }
  if (
    keys[0] === "error" && fields.get("error") === "user_cancelled_authorize"
  ) {
    return { kind: "cancelled", state };
  }
  const code = fields.get("code") ?? "";
  if (keys[0] !== "code" || !/^[\x21-\x7e]{16,4096}$/.test(code)) {
    throw new AppleDeletionCallbackError();
  }
  return { kind: "authorized", state, code };
}
