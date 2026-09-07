import { createClient } from "@supabase/supabase-js";
import {
  createAppleClientSecret,
  createAppleTokenClient,
  createLiveDependencies,
  LiveDependencyConfiguration,
} from "../delete-account/index.ts";
import { appleDeletionWebBeginHandler } from "./apple_deletion_begin.ts";
import { appleDeletionCallbackHandler } from "./apple_deletion_callback.ts";
import { appleDeletionWebCompleteHandler } from "./apple_deletion_complete.ts";
export interface AppleDeletionWebHandlers {
  begin(request: Request): Promise<Response>;
  callback(request: Request): Promise<Response>;
  complete(request: Request): Promise<Response>;
}
export function createAppleDeletionWebHandlers(
  configuration: LiveDependencyConfiguration,
): AppleDeletionWebHandlers | null {
  let projectURL: string;
  let clientID: string;
  try {
    if (
      configuration.environment("HEALTHCOMP_ENABLE_APPLE_WEB_SIGN_IN") !== "YES"
    ) return null;
    projectURL = configuration.environment("SUPABASE_URL");
    if (projectURL !== "https://xhfdfdrtxwptrwhvvlhg.supabase.co") return null;
    clientID = configuration.environment("APPLE_WEB_SIGN_IN_CLIENT_ID");
    if (
      !/^[A-Za-z0-9.-]{1,255}$/.test(clientID) ||
      clientID === configuration.environment("APPLE_SIGN_IN_CLIENT_ID")
    ) return null;
  } catch {
    return null;
  }
  const redirectURI = `${projectURL}/functions/v1/apple-deletion-callback`;
  const deletion = createLiveDependencies(configuration);
  const admin = createClient(
    projectURL,
    configuration.environment("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { fetch: configuration.fetch },
    },
  );
  async function rpc(
    name: string,
    parameters: Record<string, unknown>,
  ): Promise<unknown> {
    const { data, error } = await admin.rpc(name, parameters);
    if (error) throw new Error("apple_web_deletion_storage_unavailable");
    return data;
  }
  async function hash(value: string): Promise<string> {
    const digest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    );
    return [...digest].map((b) => b.toString(16).padStart(2, "0")).join("");
  }
  function webTokenClient() {
    return createAppleTokenClient({
      clientID,
      redirectURI,
      fetch: configuration.fetch,
      clientSecret: () =>
        createAppleClientSecret({
          clientID,
          keyID: configuration.environment("APPLE_SIGN_IN_KEY_ID"),
          teamID: configuration.environment("APPLE_SIGN_IN_TEAM_ID"),
          privateKeyPEM: configuration.environment("APPLE_SIGN_IN_PRIVATE_KEY"),
        }),
    });
  }
  const revokeNative = deletion.revokeAppleToken;
  deletion.revokeAppleToken = (token, binding) =>
    binding === clientID
      ? webTokenClient().revoke(token)
      : revokeNative(token, binding);
  return {
    begin: (request) =>
      appleDeletionWebBeginHandler(request, {
        authenticate: deletion.authenticate,
        configuration: () => ({ clientID, projectURL }),
        begin: async (record) => {
          await rpc("begin_apple_deletion_web_request", {
            target_auth_user_id: record.authUserID,
            request_id: record.requestID,
            state_digest: record.stateDigest,
            verifier_digest: record.verifierDigest,
            nonce: record.nonce,
            apple_client_id: record.clientID,
            redirect_uri: record.redirectURI,
          });
        },
      }),
    callback: (request) =>
      appleDeletionCallbackHandler(request, {
        receive: async (callback) => {
          const result = await rpc("receive_apple_deletion_web_callback", {
            state_digest: await hash(callback.state),
            authorization_code: callback.kind === "authorized"
              ? callback.code
              : null,
            was_cancelled: callback.kind === "cancelled",
          });
          if (result === null) return null;
          if (typeof result !== "string") {
            throw new Error("apple_web_deletion_contract");
          }
          return { requestID: result };
        },
      }),
    complete: (request) =>
      appleDeletionWebCompleteHandler(request, {
        deletion,
        webClient: () => ({
          clientID,
          redirectURI,
          exchange: (code) => webTokenClient().exchangeAuthorizationCode(code),
        }),
        claim: async (user, id, verifierDigest) => {
          const result = await rpc("claim_apple_deletion_web_request", {
            target_auth_user_id: user,
            request_id: id,
            verifier_digest: verifierDigest,
          });
          if (result === null) return null;
          if (
            !result || typeof result !== "object" || Array.isArray(result)
          ) throw new Error("apple_web_deletion_contract");
          const record = result as Record<string, unknown>;
          if (
            typeof record.authorization_code !== "string" ||
            typeof record.apple_client_id !== "string" ||
            typeof record.redirect_uri !== "string" ||
            typeof record.nonce !== "string"
          ) throw new Error("apple_web_deletion_contract");
          return {
            authorizationCode: record.authorization_code,
            clientID: record.apple_client_id,
            redirectURI: record.redirect_uri,
            nonce: record.nonce,
          };
        },
      }),
  };
}
