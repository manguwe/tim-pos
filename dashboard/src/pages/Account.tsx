import { useState } from 'react';
import { api, getSession, setSession } from '../api.ts';
import { Button, CopyButton, Field, FormModal, Page, useToast } from '../ui.tsx';

export function Account() {
  const s = getSession();
  const toast = useToast();
  const [step, setStep] = useState<'idle' | 'ask' | 'confirm'>('idle');
  const [secret, setSecret] = useState<{ secret: string; otpauth_url: string } | null>(null);
  const [current, setCurrent] = useState('');
  const [code, setCode] = useState('');
  if (!s) return null;
  const on = s.user.two_factor;

  const start = async () => {
    const r = await api<{ secret: string; otpauth_url: string }>('POST', '/2fa/setup', on ? { code: current.trim() } : {});
    setSecret(r);
    setStep('confirm');
  };

  return (
    <Page title="My account">
      <div className="card">
        <dl className="dl"><div><dt>Name</dt><dd>{s.user.name}</dd></div><div><dt>Email</dt><dd>{s.user.email}</dd></div>
          <div><dt>Two-factor sign-in</dt><dd>{on ? 'On' : 'Off. Turn it on: this account can issue licences.'}</dd></div></dl>
        <div className="row gap">
          <Button kind={on ? 'plain' : 'primary'} onClick={() => (on ? setStep('ask') : void start().catch((e) => toast(e.message, true)))}>{on ? 'Replace authenticator' : 'Turn on two-factor'}</Button>
          <Button onClick={() => setSession(null)}>Sign out</Button>
        </div>
      </div>
      {step === 'ask' && (
        <FormModal title="Replace authenticator" submit="Continue" onClose={() => setStep('idle')} onSubmit={start}>
          <Field label="A current code from your authenticator app" hint="This proves it is you, even if someone has your open session.">
            {(id) => <input id={id} inputMode="numeric" pattern="[0-9]{6}" maxLength={6} required value={current} onChange={(e) => setCurrent(e.target.value)} />}
          </Field>
        </FormModal>
      )}
      {step === 'confirm' && secret && (
        <FormModal title="Set up your authenticator" submit="Turn on" onClose={() => { setStep('idle'); setSecret(null); }}
          onSubmit={async () => {
            await api('POST', '/2fa/enable', { code: code.trim() });
            setSession({ ...s, user: { ...s.user, two_factor: true } });
            setStep('idle'); setSecret(null); setCode(''); setCurrent('');
            toast('Two-factor sign-in is on.');
          }}>
          <p>In your authenticator app (Google Authenticator, Microsoft Authenticator, Aegis…) choose <strong>Enter a setup key</strong> and type this key. Account: {s.user.email}, type: time based.</p>
          <div className="secret"><code data-testid="totp-secret">{secret.secret.match(/.{1,4}/g)?.join(' ')}</code><CopyButton text={secret.secret} /></div>
          <p className="small muted">On a phone you can also <a href={secret.otpauth_url}>open this link</a> to add it automatically.</p>
          <Field label="Then enter the 6-digit code it shows">{(id) => <input id={id} inputMode="numeric" pattern="[0-9]{6}" maxLength={6} required value={code} onChange={(e) => setCode(e.target.value)} />}</Field>
        </FormModal>
      )}
    </Page>
  );
}
