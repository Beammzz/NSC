'use client';

import { Suspense, useEffect, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  clearLLMLogs,
  fetchLLMLogs,
  fetchLLMSettings,
  formatDateTime,
  LLMLogRecord,
  LLMLogsPage,
  LLMSettings,
  LLMSettingsPatch,
  putLLMSettings,
} from '../../lib/api';

type TabType = 'logs' | 'settings';

export default function LLMPageWrapper() {
  return (
    <Suspense fallback={<div className="empty">Loading LLM dashboard...</div>}>
      <LLMPage />
    </Suspense>
  );
}

function LLMPage() {
  const searchParams = useSearchParams();
  const rawTab = searchParams.get('tab');
  const [activeTab, setActiveTab] = useState<TabType>(rawTab === 'settings' ? 'settings' : 'logs');

  useEffect(() => {
    const raw = searchParams.get('tab');
    if (raw === 'settings' || raw === 'logs') {
      setActiveTab(raw);
    }
  }, [searchParams]);

  const switchTab = (tab: TabType) => {
    setActiveTab(tab);
    const newUrl = new URL(window.location.href);
    newUrl.searchParams.set('tab', tab);
    window.history.replaceState(null, '', newUrl.toString());
  };

  return (
    <div>
      <h1>LLM Model</h1>
      <p className="subtitle">
        Sentence composition for the sign stream: the recognized words of one signing burst are
        buffered, and after the signer pauses they are turned into a single Thai sentence and sent
        to the app to speak.
      </p>

      <div className="tab-bar">
        <button
          type="button"
          className={`tab-btn ${activeTab === 'logs' ? 'active' : ''}`}
          onClick={() => switchTab('logs')}
        >
          LLM Logs
        </button>
        <button
          type="button"
          className={`tab-btn ${activeTab === 'settings' ? 'active' : ''}`}
          onClick={() => switchTab('settings')}
        >
          Settings
        </button>
      </div>

      {activeTab === 'logs' && <LogsView />}
      {activeTab === 'settings' && <SettingsView />}
    </div>
  );
}

/* =========================================================================
   1. LLM Logs
   ========================================================================= */

const LIMIT = 25;

function LogsView() {
  const [data, setData] = useState<LLMLogsPage | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);
  const [clearing, setClearing] = useState<boolean>(false);
  const [offset, setOffset] = useState<number>(0);
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [autoRefresh, setAutoRefresh] = useState<boolean>(true);

  async function load(showSpinner = false) {
    if (showSpinner) setLoading(true);
    try {
      const page = await fetchLLMLogs({ limit: LIMIT, offset });
      setData(page);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      if (showSpinner) setLoading(false);
    }
  }

  useEffect(() => {
    load(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [offset]);

  useEffect(() => {
    if (!autoRefresh) return;
    const interval = setInterval(() => load(false), 4000);
    return () => clearInterval(interval);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [autoRefresh, offset]);

  async function handleClear() {
    if (!window.confirm('Delete every logged LLM request? This cannot be undone.')) return;
    setClearing(true);
    setNotice(null);
    try {
      await clearLLMLogs();
      setOffset(0);
      await load(true);
      setNotice({ type: 'success', text: 'LLM request log cleared.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to clear the log: ${msg}` });
    } finally {
      setClearing(false);
    }
  }

  const records: LLMLogRecord[] = data?.records ?? [];
  const total = data?.total ?? 0;
  const failures = records.filter((r) => !r.ok).length;
  const avgLatency = records.length
    ? Math.round(records.reduce((sum, r) => sum + r.latency_ms, 0) / records.length)
    : 0;

  return (
    <div>
      <div className="grid">
        <div className="card">
          <h2>Logged compositions</h2>
          <div className="stat">{total.toLocaleString()}</div>
        </div>
        <div className="card">
          <h2>Failures on this page</h2>
          <div className="stat">
            {failures}
            <small>of {records.length}</small>
          </div>
        </div>
        <div className="card">
          <h2>Average latency</h2>
          <div className="stat">
            {avgLatency}
            <small>ms</small>
          </div>
        </div>
      </div>

      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div className="row" style={{ marginBottom: 0 }}>
          <button type="button" className="secondary" onClick={() => load(true)}>
            Refresh
          </button>
          <button type="button" className="secondary" onClick={handleClear} disabled={clearing}>
            {clearing ? 'Clearing...' : 'Clear Log'}
          </button>
        </div>
        <button
          type="button"
          className={`chip ${autoRefresh ? 'good' : 'warning'}`}
          onClick={() => setAutoRefresh((v) => !v)}
        >
          <span className="dot" />
          {autoRefresh ? 'AUTO-REFRESH ON' : 'AUTO-REFRESH OFF'}
        </button>
      </div>

      {notice && <div className={`notice ${notice.type}`}>{notice.text}</div>}
      {error && <div className="notice error">Failed to load the LLM log: {error}</div>}

      {loading && !data ? (
        <div className="empty">Loading LLM requests...</div>
      ) : records.length === 0 ? (
        <div className="empty">
          No compositions logged yet. Sentences are logged once a signing burst is composed
          through the endpoint; a disabled LLM joins the words locally and is not logged.
        </div>
      ) : (
        <div className="tablewrap">
          <table>
            <thead>
              <tr>
                <th>Time</th>
                <th>Recognized words</th>
                <th>Sentence</th>
                <th>Latency</th>
                <th>Result</th>
              </tr>
            </thead>
            <tbody>
              {records.map((r) => (
                <LogRow
                  key={r.id}
                  record={r}
                  expanded={expandedId === r.id}
                  onToggle={() => setExpandedId(expandedId === r.id ? null : r.id)}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}

      {total > LIMIT && (
        <div className="row" style={{ marginTop: '14px' }}>
          <button
            type="button"
            className="secondary"
            disabled={offset === 0}
            onClick={() => setOffset(Math.max(0, offset - LIMIT))}
          >
            Newer
          </button>
          <span style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            {offset + 1}–{Math.min(offset + LIMIT, total)} of {total.toLocaleString()}
          </span>
          <button
            type="button"
            className="secondary"
            disabled={offset + LIMIT >= total}
            onClick={() => setOffset(offset + LIMIT)}
          >
            Older
          </button>
        </div>
      )}
    </div>
  );
}

function LogRow({
  record,
  expanded,
  onToggle,
}: {
  record: LLMLogRecord;
  expanded: boolean;
  onToggle: () => void;
}) {
  let chipClass = 'good';
  let chipLabel = 'COMPOSED';
  if (!record.ok) {
    chipClass = 'critical';
    chipLabel = 'FALLBACK';
  } else if (record.fallback) {
    chipClass = 'warning';
    chipLabel = 'JOINED';
  }

  return (
    <>
      <tr onClick={onToggle} style={{ cursor: 'pointer' }}>
        <td>{formatDateTime(record.created_ms)}</td>
        <td>{record.words.join(' ')}</td>
        <td className="word">{record.sentence}</td>
        <td>{record.latency_ms} ms</td>
        <td>
          <span className={`chip ${chipClass}`}>
            <span className="dot" />
            {chipLabel}
          </span>
        </td>
      </tr>
      {expanded && (
        <tr>
          <td colSpan={5}>
            <dl className="kv">
              <dt>Model</dt>
              <dd>{record.model || '—'}</dd>
              <dt>Raw response</dt>
              <dd style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
                {record.raw || '—'}
              </dd>
              {record.error && (
                <>
                  <dt>Error</dt>
                  <dd style={{ color: 'var(--status-critical)', wordBreak: 'break-word' }}>
                    {record.error}
                  </dd>
                </>
              )}
            </dl>
          </td>
        </tr>
      )}
    </>
  );
}

/* =========================================================================
   2. Settings
   ========================================================================= */

function SettingsView() {
  const [settings, setSettings] = useState<LLMSettings | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState<boolean>(false);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  const [enabled, setEnabled] = useState<boolean>(false);
  const [endpoint, setEndpoint] = useState<string>('');
  const [apiKey, setApiKey] = useState<string>('');
  const [model, setModel] = useState<string>('');
  const [systemPrompt, setSystemPrompt] = useState<string>('');
  const [silenceMs, setSilenceMs] = useState<string>('');
  const [maxWords, setMaxWords] = useState<string>('');
  const [timeoutMs, setTimeoutMs] = useState<string>('');
  const [temperature, setTemperature] = useState<string>('');
  const [autoCleanMax, setAutoCleanMax] = useState<string>('');

  function applyToForm(s: LLMSettings) {
    setSettings(s);
    setEnabled(s.enabled);
    setEndpoint(s.endpoint);
    setModel(s.model);
    setSystemPrompt(s.system_prompt);
    setSilenceMs(String(s.silence_ms));
    setMaxWords(String(s.max_words));
    setTimeoutMs(String(s.timeout_ms));
    setTemperature(String(s.temperature));
    setAutoCleanMax(String(s.auto_clean_max_logs));
    // Never pre-fill the key field: the server only ever sends the mask.
    setApiKey('');
  }

  useEffect(() => {
    (async () => {
      try {
        applyToForm(await fetchLLMSettings());
        setError(null);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  // Number inputs are optional: an unparsable field keeps the stored value
  // rather than silently writing 0.
  function numberPatch(raw: string, parse: (s: string) => number): number | undefined {
    const trimmed = raw.trim();
    if (trimmed === '') return undefined;
    const value = parse(trimmed);
    return Number.isNaN(value) ? undefined : value;
  }

  async function handleSave(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setNotice(null);
    const patch: LLMSettingsPatch = {
      enabled,
      endpoint: endpoint.trim(),
      model: model.trim(),
      system_prompt: systemPrompt,
      silence_ms: numberPatch(silenceMs, (s) => parseInt(s, 10)),
      max_words: numberPatch(maxWords, (s) => parseInt(s, 10)),
      timeout_ms: numberPatch(timeoutMs, (s) => parseInt(s, 10)),
      temperature: numberPatch(temperature, parseFloat),
      auto_clean_max_logs: numberPatch(autoCleanMax, (s) => parseInt(s, 10)),
    };
    // Only send the key when the admin typed one, so an untouched field keeps
    // the stored secret.
    if (apiKey.trim() !== '') patch.api_key = apiKey.trim();

    try {
      applyToForm(await putLLMSettings(patch));
      setNotice({ type: 'success', text: 'LLM settings saved.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to save settings: ${msg}` });
    } finally {
      setSaving(false);
    }
  }

  async function handleClearKey() {
    if (!window.confirm('Remove the stored API key? Composition falls back to joining the words.')) {
      return;
    }
    setSaving(true);
    setNotice(null);
    try {
      applyToForm(await putLLMSettings({ api_key: '', enabled: false }));
      setNotice({ type: 'success', text: 'API key removed.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to remove the key: ${msg}` });
    } finally {
      setSaving(false);
    }
  }

  if (loading) return <div className="empty">Loading LLM settings...</div>;
  if (error) return <div className="notice error">Failed to load LLM settings: {error}</div>;
  if (!settings) return <div className="empty">No LLM settings available.</div>;

  const live = settings.enabled && settings.api_key_set;

  return (
    <form onSubmit={handleSave} style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      {notice && <div className={`notice ${notice.type}`}>{notice.text}</div>}

      <div className="card">
        <h2>Status</h2>
        <div className="row" style={{ marginBottom: 0 }}>
          <span className={`chip ${live ? 'good' : 'warning'}`}>
            <span className="dot" />
            {live ? 'COMPOSING VIA LLM' : 'JOINING WORDS LOCALLY'}
          </span>
          <span className="chip info">
            <span className="dot" />
            {settings.api_key_set ? `KEY ${settings.api_key_masked}` : 'NO API KEY'}
          </span>
        </div>
        <p style={{ color: 'var(--text-muted)', fontSize: '13px', marginBottom: 0 }}>
          Without a key the backend still ends each sentence on a pause and sends it to the app —
          it just concatenates the recognized words instead of calling a model, so speech never
          depends on the endpoint being up.
        </p>
      </div>

      <div className="card">
        <h2>Endpoint</h2>
        <label className="field">
          <span>
            <input
              type="checkbox"
              checked={enabled}
              onChange={(e) => setEnabled(e.target.checked)}
              style={{ marginRight: '8px' }}
            />
            Use the LLM to compose sentences
          </span>
        </label>
        <label className="field">
          <span>OpenAI-compatible chat completions URL</span>
          <input
            type="url"
            className="wide"
            value={endpoint}
            onChange={(e) => setEndpoint(e.target.value)}
            placeholder={settings.default_endpoint}
          />
          <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
            Full path, e.g. {settings.default_endpoint}
          </small>
        </label>
        <label className="field">
          <span>API key</span>
          <input
            type="password"
            className="wide"
            value={apiKey}
            onChange={(e) => setApiKey(e.target.value)}
            placeholder={settings.api_key_set ? `stored: ${settings.api_key_masked}` : 'not set'}
            autoComplete="new-password"
          />
          <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
            Leave blank to keep the stored key. Sent to the endpoint as a Bearer token; it never
            leaves the server and never reaches the mobile app.
          </small>
        </label>
        {settings.api_key_set && (
          <button type="button" className="secondary" onClick={handleClearKey} disabled={saving}>
            Remove stored key
          </button>
        )}
        <label className="field" style={{ marginTop: '12px' }}>
          <span>Model</span>
          <input
            type="text"
            value={model}
            onChange={(e) => setModel(e.target.value)}
            placeholder={settings.default_model}
          />
        </label>
      </div>

      <div className="card">
        <h2>System prompt</h2>
        <p style={{ color: 'var(--text-muted)', fontSize: '13px', marginTop: 0 }}>
          The recognized words are sent as the user message, space-separated. The server still
          rejects any reply that drops one of them and falls back to joining the words, so the
          prompt cannot loosen that guarantee.
        </p>
        <textarea value={systemPrompt} onChange={(e) => setSystemPrompt(e.target.value)} />
        <button
          type="button"
          className="secondary"
          style={{ marginTop: '8px' }}
          onClick={() => setSystemPrompt(settings.default_system_prompt)}
        >
          Reset to default prompt
        </button>
      </div>

      <div className="card">
        <h2>Sentence boundary &amp; limits</h2>
        <label className="field">
          <span>Pause before a sentence is composed (ms)</span>
          <input
            type="number"
            step="100"
            min="200"
            max="30000"
            value={silenceMs}
            onChange={(e) => setSilenceMs(e.target.value)}
          />
          <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
            How long the signer must stop producing new words before the buffer is composed and
            spoken. 200–30000 ms.
          </small>
        </label>
        <label className="field">
          <span>Maximum words per sentence</span>
          <input
            type="number"
            step="1"
            min="1"
            max="64"
            value={maxWords}
            onChange={(e) => setMaxWords(e.target.value)}
          />
          <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
            The buffer composes early once this many words accumulate, even without a pause.
          </small>
        </label>
        <label className="field">
          <span>Request timeout (ms)</span>
          <input
            type="number"
            step="500"
            min="500"
            max="120000"
            value={timeoutMs}
            onChange={(e) => setTimeoutMs(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Temperature</span>
          <input
            type="number"
            step="0.1"
            min="0"
            max="2"
            value={temperature}
            onChange={(e) => setTemperature(e.target.value)}
          />
        </label>
        <label className="field">
          <span>Max LLM log entries retained (0 to keep all)</span>
          <input
            type="number"
            step="1"
            min="0"
            value={autoCleanMax}
            onChange={(e) => setAutoCleanMax(e.target.value)}
          />
        </label>
      </div>

      <div className="row" style={{ marginBottom: 0 }}>
        <button type="submit" disabled={saving}>
          {saving ? 'Saving...' : 'Save LLM Settings'}
        </button>
      </div>
    </form>
  );
}
