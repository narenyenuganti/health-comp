import { assertEquals } from "@std/assert";

interface WorkerResult {
  status: "ok" | "error";
  responseStatus?: number;
  responseBody?: unknown;
  name?: string;
  message?: string;
}

function workerResult(worker: Worker): Promise<WorkerResult> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("hosted edge worker probe timed out")),
      10_000,
    );
    worker.onmessage = (event: MessageEvent<WorkerResult>) => {
      clearTimeout(timeout);
      resolve(event.data);
    };
    worker.onerror = (event) => {
      clearTimeout(timeout);
      reject(event.error ?? new Error(event.message));
    };
  });
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
    const result = await workerResult(worker);

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
