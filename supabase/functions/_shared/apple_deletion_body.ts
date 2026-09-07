export async function readAppleDeletionBody(
  request: Request,
  maximumBytes: number,
  timeoutMilliseconds = 5_000,
): Promise<Uint8Array> {
  const invalid = () => new Error("invalid_apple_deletion_body");
  if (
    !request.body || !Number.isSafeInteger(maximumBytes) ||
    maximumBytes < 1 || maximumBytes > 16_384 ||
    !Number.isFinite(timeoutMilliseconds) || timeoutMilliseconds <= 0 ||
    timeoutMilliseconds > 5_000
  ) throw invalid();
  const reader = request.body.getReader();
  const bytes = new Uint8Array(maximumBytes);
  let length = 0;
  let rejectRead!: (error: Error) => void;
  const interrupted = new Promise<never>((_, reject) => {
    rejectRead = reject;
  });
  const abort = () => rejectRead(invalid());
  const deadline = performance.now() + timeoutMilliseconds;
  const timer = setTimeout(abort, timeoutMilliseconds);
  request.signal.addEventListener("abort", abort, { once: true });
  try {
    const read = async () => {
      while (true) {
        if (request.signal.aborted || performance.now() >= deadline) {
          throw invalid();
        }
        const { done, value } = await reader.read();
        if (request.signal.aborted || performance.now() >= deadline) {
          throw invalid();
        }
        if (done) return bytes.slice(0, length);
        if (length + value.byteLength > maximumBytes) throw invalid();
        bytes.set(value, length);
        length += value.byteLength;
      }
    };
    return await Promise.race([read(), interrupted]);
  } catch {
    // A producer's cancel hook may never settle. Request cancellation must not
    // wait for it, and underlying error text must not enter the response.
    void reader.cancel().catch(() => {});
    throw invalid();
  } finally {
    clearTimeout(timer);
    request.signal.removeEventListener("abort", abort);
    reader.releaseLock();
  }
}
