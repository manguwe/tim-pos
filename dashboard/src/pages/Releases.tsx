import { useState } from 'react';
import { api, type Release } from '../api.ts';
import { bytes, fmtDate } from '../format.ts';
import { Button, CopyButton, Empty, ErrorBox, Field, FormModal, Loading, Page, useAsync, useToast } from '../ui.tsx';

export function Releases() {
  const list = useAsync(() => api<{ releases: Release[] }>('GET', '/releases'), []);
  const [open, setOpen] = useState(false);
  const toast = useToast();
  return (
    <Page title="App releases" actions={<Button kind="primary" onClick={() => setOpen(true)}>Publish release</Button>}>
      <p className="muted">Phones check this list. A release newer than the phone shows an update notice; raising "oldest build allowed" forces older phones to update before they can sell.</p>
      {list.error && <ErrorBox error={list.error} retry={list.reload} />}
      {!list.data && !list.error && <Loading />}
      {list.data && list.data.releases.length === 0 && <Empty>No release published yet.</Empty>}
      {list.data && list.data.releases.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Version</th><th className="num">Build</th><th className="num">Oldest allowed</th><th>Published</th><th>Size</th><th>Checksum</th></tr></thead>
          <tbody>{list.data.releases.map((r) => (
            <tr key={r.id}>
              <td><a href={r.apk_url} target="_blank" rel="noreferrer noopener">{r.version}</a>{r.notes && <div className="muted small">{r.notes}</div>}</td>
              <td className="num">{r.build_number}</td><td className="num">{r.min_supported_build}</td><td>{fmtDate(r.published_at)}</td><td>{bytes(r.size_bytes)}</td>
              <td><code className="small">{r.sha256.slice(0, 12)}…</code> <CopyButton text={r.sha256} /></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
      {open && <Publish onClose={() => setOpen(false)} onDone={() => { setOpen(false); toast('Release published.'); list.reload(); }} />}
    </Page>
  );
}

function Publish({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [version, setVersion] = useState('');
  const [build, setBuild] = useState('');
  const [min, setMin] = useState('0');
  const [sha, setSha] = useState('');
  const [size, setSize] = useState('');
  const [url, setUrl] = useState('https://');
  const [notes, setNotes] = useState('');
  return (
    <FormModal title="Publish release" submit="Publish" wide onClose={onClose}
      onSubmit={async () => {
        const hash = sha.trim().toLowerCase();
        if (!/^[0-9a-f]{64}$/.test(hash)) throw new Error('The checksum is 64 letters and digits (SHA-256 of the APK).');
        await api('POST', '/releases', { version, build_number: Number(build), min_supported_build: Number(min), sha256: hash, size_bytes: Number(size), apk_url: url.trim(), ...(notes.trim() ? { notes } : {}) });
        onDone();
      }}>
      <div className="grid2">
        <Field label="Version" hint="For example 1.4.0">{(id) => <input id={id} required maxLength={40} value={version} onChange={(e) => setVersion(e.target.value)} />}</Field>
        <Field label="Build number" hint="The number after + in the app's version.">{(id) => <input id={id} type="number" min={1} step={1} required value={build} onChange={(e) => setBuild(e.target.value)} />}</Field>
        <Field label="Oldest build allowed" hint="0 means no one is forced to update.">{(id) => <input id={id} type="number" min={0} step={1} required value={min} onChange={(e) => setMin(e.target.value)} />}</Field>
        <Field label="File size (bytes)">{(id) => <input id={id} type="number" min={1} step={1} required value={size} onChange={(e) => setSize(e.target.value)} />}</Field>
      </div>
      <Field label="Download address" hint="Must start with https://">{(id) => <input id={id} type="url" required value={url} onChange={(e) => setUrl(e.target.value)} />}</Field>
      <Field label="SHA-256 checksum" hint="Run: sha256sum tim-pos.apk">{(id) => <input id={id} required className="mono" value={sha} onChange={(e) => setSha(e.target.value)} />}</Field>
      <Field label="Release notes (optional)">{(id) => <textarea id={id} rows={3} maxLength={4000} value={notes} onChange={(e) => setNotes(e.target.value)} />}</Field>
    </FormModal>
  );
}
