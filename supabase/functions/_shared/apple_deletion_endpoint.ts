import { LiveDependencyConfiguration } from "../delete-account/index.ts";
import { createAppleDeletionTransport } from "./apple_deletion_transport.ts";
import {
  AppleDeletionWebHandlers,
  createAppleDeletionWebHandlers,
} from "./apple_deletion_live.ts";

export async function appleDeletionEndpoint(
  operation: keyof AppleDeletionWebHandlers,
  request: Request,
  configuration: LiveDependencyConfiguration = {
    environment: (name) => Deno.env.get(name)?.trim() ?? "",
    fetch,
  },
): Promise<Response> {
  const unavailable = () =>
    new Response(null, {
      status: 503,
      headers: {
        "cache-control": "no-store",
        "referrer-policy": "no-referrer",
      },
    });
  const transport = createAppleDeletionTransport(configuration.fetch);
  try {
    const handlers = createAppleDeletionWebHandlers({
      ...configuration,
      fetch: transport.fetch,
    });
    if (!handlers) return unavailable();
    const response = await handlers[operation](request);
    // Preserve an actual server-confirmed completion, but don't misreport
    // budget exhaustion during authentication as invalid user credentials.
    if (transport.expired && response.status !== 200) return unavailable();
    return response;
  } catch {
    // Never expose provider, credential or SDK construction diagnostics.
    return unavailable();
  } finally {
    transport.close();
  }
}
