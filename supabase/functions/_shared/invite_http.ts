import { createClient } from "@supabase/supabase-js";

export interface InviteRpcError {
  message: string;
  code?: string;
  details?: string;
}

export interface InviteRpcClient {
  auth: {
    getUser(): Promise<{
      data: { user: { id: string } | null };
      error: { message: string } | null;
    }>;
  };
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ data: string | null; error: InviteRpcError | null }>;
}

export interface HandlerDependencies {
  createUserClient(authorization: string): InviteRpcClient;
}

export interface ServiceClientDependencies {
  createServiceClient(): InviteRpcClient;
}

export const defaultDependencies: HandlerDependencies = {
  createUserClient(authorization: string): InviteRpcClient {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !supabaseAnonKey) {
      throw new Error("Supabase function environment is not configured");
    }
    return createClient(supabaseUrl, supabaseAnonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: authorization } },
    }) as unknown as InviteRpcClient;
  },
};

export const defaultServiceDependencies: ServiceClientDependencies = {
  createServiceClient(): InviteRpcClient {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseServiceRoleKey) {
      throw new Error("Supabase service environment is not configured");
    }
    return createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    }) as unknown as InviteRpcClient;
  },
};

export function jsonResponse(
  status: number,
  body: Record<string, unknown>,
): Response {
  return Response.json(body, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
    },
  });
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
): Response {
  return jsonResponse(status, { error: { code, message } });
}

export function bearerAuthorization(request: Request): string | null {
  const value = request.headers.get("authorization");
  return value && /^Bearer\s+\S+$/i.test(value) ? value : null;
}

export async function authenticatedClient(
  request: Request,
  dependencies: HandlerDependencies,
): Promise<InviteRpcClient | null> {
  return (await authenticatedContext(request, dependencies))?.client ?? null;
}

export async function authenticatedContext(
  request: Request,
  dependencies: HandlerDependencies,
): Promise<{ client: InviteRpcClient; userId: string } | null> {
  const authorization = bearerAuthorization(request);
  if (!authorization) return null;
  const client = dependencies.createUserClient(authorization);
  const { data, error } = await client.auth.getUser();
  return error || !data.user ? null : { client, userId: data.user.id };
}

export async function sha256Hex(value: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", Uint8Array.from(value).buffer),
  );
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}

export function base64UrlEncode(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/,
    "",
  );
}

export function base64UrlDecode(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]{43}$/.test(value)) return null;
  try {
    const base64 = value.replaceAll("-", "+").replaceAll("_", "/") + "=";
    const decoded = atob(base64);
    if (decoded.length !== 32) return null;
    return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}
