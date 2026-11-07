/** Counts failures per key and blocks the key for a window once the limit is reached. */
export class FailureLimiter {
  private readonly max: number;
  private readonly windowMs: number;
  private readonly now: () => number;
  private readonly entries = new Map<string, { count: number; resetAt: number }>();

  constructor(max: number, windowMs: number, now: () => number) {
    this.max = max;
    this.windowMs = windowMs;
    this.now = now;
  }

  blocked(key: string): boolean {
    const e = this.entries.get(key);
    return !!e && e.resetAt > this.now() && e.count >= this.max;
  }

  fail(key: string): void {
    const t = this.now();
    const e = this.entries.get(key);
    if (!e || e.resetAt <= t) this.entries.set(key, { count: 1, resetAt: t + this.windowMs });
    else e.count += 1;
    if (this.entries.size > 10_000) this.sweep(t);
  }

  succeed(key: string): void {
    this.entries.delete(key);
  }

  private sweep(t: number): void {
    for (const [k, e] of this.entries) if (e.resetAt <= t) this.entries.delete(k);
  }
}
