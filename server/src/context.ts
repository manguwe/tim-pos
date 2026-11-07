import type { Config } from './config.ts';
import type { Db } from './db.ts';
import { FailureLimiter } from './limiter.ts';

export interface Ctx {
  db: Db;
  config: Config;
  now: () => number;
  /** Failed device activations, per client address. */
  activationLimiter: FailureLimiter;
  /** Failed vendor sign-ins. Blocking one address+email pair stops a stranger locking the real vendor out from elsewhere. */
  loginPairLimiter: FailureLimiter;
  loginIpLimiter: FailureLimiter;
  /** A high ceiling per email, so a spread-out guessing attack is still slowed. */
  loginEmailLimiter: FailureLimiter;
}

export function makeCtx(db: Db, config: Config, now: () => number = Date.now): Ctx {
  return {
    db,
    config,
    now,
    activationLimiter: new FailureLimiter(10, 15 * 60_000, now),
    loginPairLimiter: new FailureLimiter(5, 15 * 60_000, now),
    loginIpLimiter: new FailureLimiter(20, 15 * 60_000, now),
    loginEmailLimiter: new FailureLimiter(100, 60 * 60_000, now),
  };
}
