import { appleDeletionEndpoint } from "../_shared/apple_deletion_endpoint.ts";
import { LiveDependencyConfiguration } from "../delete-account/index.ts";

export function handler(
  request: Request,
  configuration?: LiveDependencyConfiguration,
) {
  return appleDeletionEndpoint("callback", request, configuration);
}
if (import.meta.main) Deno.serve((request) => handler(request));
