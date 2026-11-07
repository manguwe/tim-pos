import { FailureLimiter } from './limiter.ts';
export function makeCtx(db, config, now = Date.now) {
    return {
        db,
        config,
        now,
        activationLimiter: new FailureLimiter(10, 15 * 60000, now),
        loginPairLimiter: new FailureLimiter(5, 15 * 60000, now),
        loginIpLimiter: new FailureLimiter(20, 15 * 60000, now),
        loginEmailLimiter: new FailureLimiter(100, 60 * 60000, now),
    };
}
