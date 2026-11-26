import { api, type FeatureInfo } from '../api.ts';
import { useAsync } from '../ui.tsx';

/** Tick boxes for what a plan or licence includes. The list of features comes from the server. */
export function FeaturePicker({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const q = useAsync(() => api<{ features: FeatureInfo[] }>('GET', '/features'), []);
  const known = q.data?.features ?? [];
  const extra = value.filter((v) => !known.some((k) => k.key === v));
  const toggle = (key: string, on: boolean) => onChange(on ? [...value.filter((v) => v !== key), key] : value.filter((v) => v !== key));
  return (
    <fieldset className="features">
      <legend>What is included</legend>
      {q.error && <p className="muted">Could not load the feature list.</p>}
      {known.map((f) => (
        <label className="check feature" key={f.key}>
          <input type="checkbox" checked={value.includes(f.key)} onChange={(e) => toggle(f.key, e.target.checked)} />
          <span><strong>{f.label}</strong><br /><span className="muted small">{f.description}</span></span>
        </label>
      ))}
      {extra.map((k) => (
        <label className="check feature" key={k}>
          <input type="checkbox" checked onChange={() => toggle(k, false)} />
          <span><strong>{k}</strong><br /><span className="muted small">Not in the list above. Untick to remove.</span></span>
        </label>
      ))}
    </fieldset>
  );
}
