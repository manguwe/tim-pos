/** Counts failures per key and blocks the key for a window once the limit is reached. */
export class FailureLimiter {
    max;
    windowMs;
    now;
    entries = new Map();
    constructor(max, windowMs, now) {
        this.max = max;
        this.windowMs = windowMs;
        this.now = now;
    }
    blocked(key) {
        const e = this.entries.get(key);
        return !!e && e.resetAt > this.now() && e.count >= this.max;
    }
    fail(key) {
        const t = this.now();
        const e = this.entries.get(key);
        if (!e || e.resetAt <= t)
            this.entries.set(key, { count: 1, resetAt: t + this.windowMs });
        else
            e.count += 1;
        if (this.entries.size > 10000)
            this.sweep(t);
    }
    succeed(key) {
        this.entries.delete(key);
    }
    sweep(t) {
        for (const [k, e] of this.entries)
            if (e.resetAt <= t)
                this.entries.delete(k);
    }
}
