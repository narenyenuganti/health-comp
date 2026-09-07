export function createAppleDeletionTransport(
  transport: typeof fetch,
  timeoutMilliseconds = 60_000,
) {
  if (
    !Number.isFinite(timeoutMilliseconds) || timeoutMilliseconds <= 0 ||
    timeoutMilliseconds > 60_000
  ) throw new Error("invalid_deletion_transport_budget");
  const controller = new AbortController();
  const deadline = performance.now() + timeoutMilliseconds;
  let timedOut = false;
  const abortError = () =>
    new DOMException("deletion_transport_stopped", "AbortError");
  const expire = () => {
    timedOut = true;
    controller.abort(abortError());
  };
  const timer = setTimeout(expire, timeoutMilliseconds);
  const scopedFetch: typeof fetch = async (input, init) => {
    if (performance.now() >= deadline) expire();
    const callerSignal = init?.signal ??
      (input instanceof Request ? input.signal : null);
    const signal = callerSignal
      ? AbortSignal.any([controller.signal, callerSignal])
      : controller.signal;
    if (signal.aborted) throw abortError();
    // Await the real transport. Never detach an RPC/deletion workflow through
    // Promise.race: a timeout cannot prove remote rollback or non-acceptance.
    return await transport(input, { ...init, signal });
  };
  return {
    fetch: scopedFetch,
    close() {
      clearTimeout(timer);
      controller.abort(abortError());
    },
    get expired() {
      return timedOut || performance.now() >= deadline;
    },
  };
}
