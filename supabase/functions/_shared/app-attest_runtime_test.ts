import { assertEquals } from "@std/assert";

interface WorkerResult {
  status: "ok" | "error";
  responseStatus?: number;
  responseBody?: unknown;
  name?: string;
  message?: string;
}

Deno.test("score endpoint boots with the hosted edge process shim", async () => {
  const moduleURL = new URL(
    "../submit-score-revision/index.ts",
    import.meta.url,
  ).href;
  const workerSource = `
    globalThis.process = { pid: undefined };
    globalThis.global = globalThis;
    try {
      const module = await import(${JSON.stringify(moduleURL)});
      const response = await module.submitScoreRevisionHandler(
        new Request("http://localhost/submit-score-revision", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
        }),
      );
      postMessage({
        status: "ok",
        responseStatus: response.status,
        responseBody: await response.json(),
      });
    } catch (error) {
      postMessage({
        status: "error",
        name: error instanceof Error ? error.name : typeof error,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  `;
  const workerURL = URL.createObjectURL(
    new Blob([workerSource], { type: "text/javascript" }),
  );
  const worker = new Worker(workerURL, { type: "module" });

  try {
    const result = await new Promise<WorkerResult>((resolve, reject) => {
      worker.onmessage = (event: MessageEvent<WorkerResult>) => {
        resolve(event.data);
      };
      worker.onerror = (event) => {
        reject(event.error ?? new Error(event.message));
      };
    });

    assertEquals(result, {
      status: "ok",
      responseStatus: 400,
      responseBody: {
        error: {
          code: "invalid_request",
          message: "Invalid score revision",
        },
      },
    });
  } finally {
    worker.terminate();
    URL.revokeObjectURL(workerURL);
  }
});
