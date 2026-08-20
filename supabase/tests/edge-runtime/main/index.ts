Deno.serve(async (request: Request) => {
  if (new URL(request.url).pathname === "/health") {
    return Response.json({ ok: true });
  }

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: "/fixture",
      memoryLimitMb: 150,
      workerTimeoutMs: 10_000,
      noModuleCache: true,
      noNpm: true,
      importMapPath: "/fixture/deno.json",
      envVars: [],
      forceCreate: true,
      customModuleRoot: "",
      cpuTimeSoftLimitMs: 5_000,
      cpuTimeHardLimitMs: 10_000,
      staticPatterns: [],
      decoratorType: "tc39",
      maybeEntrypoint: "file:///fixture/index.ts",
      context: { useReadSyncFileAPI: true },
    });
    return await worker.fetch(request);
  } catch (error) {
    return Response.json(
      {
        ok: false,
        category: error instanceof Error ? error.name : typeof error,
        code: "worker_failure",
      },
      { status: 500 },
    );
  }
});
