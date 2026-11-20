// make check's output: one line for each test that fails, which for a rule is file:line and the fix, then
// one line of totals. A failure that is not a breach also prints its error, and a file that crashes prints
// what it wrote to stderr.
export default async function* reporter(events) {
  let passed = 0;
  let failed = 0;
  for await (const { type, data } of events) {
    if (type === "test:stderr") yield data.message;
    if (data?.nesting !== 0) continue;
    if (type === "test:pass") passed++;
    if (type !== "test:fail") continue;
    failed++;
    const error = data.details.error.cause ?? data.details.error;
    const message = String(error?.message ?? error);
    yield message === data.name ? `${data.name}\n` : `${data.name}\n  ${message.replace(/\n/g, "\n  ")}\n`;
  }
  yield failed ? `check: fail, ${failed} of ${passed + failed} tests\n` : `check: pass, ${passed} tests\n`;
}
