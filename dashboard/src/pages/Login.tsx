import { useState } from 'react';
import { ApiError, login, setSession } from '../api.ts';
import { Link } from '../router.tsx';
import { Button, Field, errorText } from '../ui.tsx';

export function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [needCode, setNeedCode] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      setSession(await login(email.trim(), password, needCode ? code.trim() : undefined));
    } catch (err) {
      if (err instanceof ApiError && err.code === 'code_required') {
        setNeedCode(true);
        if (code) setError('That code is not correct. Wait for the next one and try again.');
      } else {
        setError(errorText(err));
      }
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login">
      <form className="card login-card" onSubmit={submit}>
        <div className="brand-mark" aria-hidden="true">T</div>
        <h1>TIM-POS</h1>
        <p className="muted">Vendor dashboard. Sign in to manage shops and licences.</p>
        <Field label="Email">{(id) => <input id={id} type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} disabled={needCode} />}</Field>
        <Field label="Password">{(id) => <input id={id} type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} disabled={needCode} />}</Field>
        {needCode && (
          <Field label="Code from your authenticator app" hint="Six digits. A code works once.">
            {(id) => <input id={id} inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required autoFocus value={code} onChange={(e) => setCode(e.target.value)} />}
          </Field>
        )}
        {error && <div className="alert alert-bad" role="alert">{error}</div>}
        <Button type="submit" kind="primary" busy={busy} className="wide">{needCode ? 'Verify and sign in' : 'Sign in'}</Button>
        <p className="muted small center-text">Own a shop? <Link to="/owner">Shop owner sign-in</Link></p>
      </form>
    </main>
  );
}
