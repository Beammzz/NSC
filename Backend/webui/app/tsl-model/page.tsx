'use client';

import { Suspense, useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  clearPredictions,
  fetchPredictions,
  fetchStatus,
  formatTime,
  isIdleWord,
  pct,
  PredictionRecord,
  PredictionsPage,
  putSettings,
  putTuning,
  Status,
  Tuning,
  UploadResult,
} from '../../lib/api';

type TabType = 'predictions' | 'logs' | 'settings';

export default function TSLModelPageWrapper() {
  return (
    <Suspense fallback={<div className="empty">Loading TSL Model Dashboard...</div>}>
      <TSLModelPage />
    </Suspense>
  );
}

function TSLModelPage() {
  const searchParams = useSearchParams();
  const rawTab = searchParams.get('tab');
  let initialTab: TabType = 'predictions';
  if (rawTab === 'settings' || rawTab === 'tuning' || rawTab === 'upload') {
    initialTab = 'settings';
  } else if (rawTab === 'predictions' || rawTab === 'logs') {
    initialTab = rawTab;
  }
  const [activeTab, setActiveTab] = useState<TabType>(initialTab);

  useEffect(() => {
    const raw = searchParams.get('tab');
    if (raw === 'settings' || raw === 'tuning' || raw === 'upload') {
      setActiveTab('settings');
    } else if (raw === 'predictions' || raw === 'logs') {
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
      <h1>TSL Model</h1>
      <p className="subtitle">Manage Thai Sign Language recognition predictions, live AI service logs, model deployments, and system settings</p>

      <div className="tab-bar">
        <button
          type="button"
          className={`tab-btn ${activeTab === 'predictions' ? 'active' : ''}`}
          onClick={() => switchTab('predictions')}
        >
          Predictions Log
        </button>
        <button
          type="button"
          className={`tab-btn ${activeTab === 'logs' ? 'active' : ''}`}
          onClick={() => switchTab('logs')}
        >
          AI Service Logs
        </button>
        <button
          type="button"
          className={`tab-btn ${activeTab === 'settings' ? 'active' : ''}`}
          onClick={() => switchTab('settings')}
        >
          Settings
        </button>
      </div>

      {activeTab === 'predictions' && <PredictionsView />}
      {activeTab === 'logs' && <LogsView />}
      {activeTab === 'settings' && <SettingsView />}
    </div>
  );
}

/* =========================================================================
   1. Predictions View
   ========================================================================= */
const LIMIT = 25;

function PredictionsView() {
  const [data, setData] = useState<PredictionsPage | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);
  const [clearing, setClearing] = useState<boolean>(false);

  // Filter & Pagination state
  const [wordFilter, setWordFilter] = useState<string>('');
  const [activeWord, setActiveWord] = useState<string>('');
  const [offset, setOffset] = useState<number>(0);
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const [isStreaming, setIsStreaming] = useState<boolean>(true);

  async function handleClearDatabase() {
    if (!window.confirm('Are you sure you want to clear all prediction records from the database?')) {
      return;
    }
    setClearing(true);
    setNotice(null);
    setError(null);
    try {
      await clearPredictions();
      setNotice({ type: 'success', text: 'Prediction database cleared successfully.' });
      setExpandedId(null);
      setOffset(0);
      await loadPredictions(activeWord, 0);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setClearing(false);
    }
  }

  async function loadPredictions(word: string, currentOffset: number, silent = false) {
    if (!silent) setLoading(true);
    setError(null);
    try {
      const res = await fetchPredictions({
        word: word || undefined,
        limit: LIMIT,
        offset: currentOffset,
      });
      setData(res);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      if (!silent) setLoading(false);
    }
  }

  useEffect(() => {
    loadPredictions(activeWord, offset);
  }, [activeWord, offset]);

  useEffect(() => {
    if (!isStreaming) return;
    const interval = setInterval(() => {
      loadPredictions(activeWord, offset, true);
    }, 1500);
    return () => clearInterval(interval);
  }, [isStreaming, activeWord, offset]);

  function handleFilterSubmit(e: React.FormEvent) {
    e.preventDefault();
    setOffset(0);
    setExpandedId(null);
    setActiveWord(wordFilter.trim());
  }

  function handleResetFilter() {
    setWordFilter('');
    setActiveWord('');
    setOffset(0);
    setExpandedId(null);
  }

  const records = data?.records || [];
  const total = data?.total || 0;
  const hasPrev = offset > 0;
  const hasNext = offset + LIMIT < total;

  return (
    <div>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
        <form onSubmit={handleFilterSubmit} className="row" style={{ marginBottom: 0 }}>
          <div>
            <label className="field" style={{ marginBottom: 0 }}>
              <span>Filter by Word</span>
              <input
                type="text"
                placeholder="e.g. สวัสดี"
                value={wordFilter}
                onChange={(e) => setWordFilter(e.target.value)}
              />
            </label>
          </div>
          <button type="submit">Filter</button>
          {activeWord && (
            <button type="button" className="secondary" onClick={handleResetFilter}>
              Clear
            </button>
          )}
        </form>

        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span className={`chip ${isStreaming ? 'good' : 'info'}`}>
            <span className="dot" />
            {isStreaming ? 'STREAMING LIVE' : 'STREAMING PAUSED'}
          </span>
          <button
            type="button"
            className="secondary"
            onClick={() => setIsStreaming((prev) => !prev)}
          >
            {isStreaming ? 'Pause Stream' : 'Resume Stream'}
          </button>
          <button
            type="button"
            className="secondary"
            disabled={clearing}
            onClick={handleClearDatabase}
            style={{ borderColor: 'var(--status-critical)', color: 'var(--status-critical)' }}
          >
            {clearing ? 'Clearing...' : 'Clear Database'}
          </button>
        </div>
      </div>

      {notice && (
        <div className={`notice ${notice.type}`}>
          {notice.text}
        </div>
      )}
      {error && (
        <div className="notice error">
          Failed to load predictions: {error}
        </div>
      )}

      <div className="tablewrap">
        <table>
          <thead>
            <tr>
              <th>Timestamp</th>
              <th>Word</th>
              <th>Confidence</th>
              <th>Status</th>
              <th>Inference</th>
            </tr>
          </thead>
          <tbody>
            {loading && records.length === 0 ? (
              <tr>
                <td colSpan={5} className="empty">
                  Loading prediction records...
                </td>
              </tr>
            ) : records.length === 0 ? (
              <tr>
                <td colSpan={5} className="empty">
                  No prediction records found.
                </td>
              </tr>
            ) : (
              records.map((rec: PredictionRecord) => {
                const isExpanded = expandedId === rec.id;
                return (
                  <FragmentRow
                    key={rec.id}
                    record={rec}
                    isExpanded={isExpanded}
                    onToggle={() => setExpandedId(isExpanded ? null : rec.id)}
                  />
                );
              })
            )}
          </tbody>
        </table>
      </div>

      <div className="row" style={{ marginTop: '14px', justifyContent: 'space-between', alignItems: 'center' }}>
        <div style={{ color: 'var(--text-secondary)' }}>
          Showing {records.length > 0 ? offset + 1 : 0}–{Math.min(offset + records.length, total)} of {total}
        </div>
        <div className="row" style={{ marginBottom: 0 }}>
          <button
            type="button"
            className="secondary"
            disabled={!hasPrev || loading}
            onClick={() => {
              setExpandedId(null);
              setOffset(Math.max(0, offset - LIMIT));
            }}
          >
            Previous
          </button>
          <button
            type="button"
            className="secondary"
            disabled={!hasNext || loading}
            onClick={() => {
              setExpandedId(null);
              setOffset(offset + LIMIT);
            }}
          >
            Next
          </button>
        </div>
      </div>
    </div>
  );
}

function FragmentRow({
  record,
  isExpanded,
  onToggle,
}: {
  record: PredictionRecord;
  isExpanded: boolean;
  onToggle: () => void;
}) {
  const isIdle = isIdleWord(record.word, record.is_idle);
  const displayWord = isIdle ? '—' : record.word;

  return (
    <>
      <tr className="expandable" onClick={onToggle}>
        <td>{formatTime(record.created_ms)}</td>
        <td className="word" style={{ color: isIdle ? 'var(--text-muted)' : 'inherit' }}>
          {displayWord}
        </td>
        <td>
          <div className="meter">
            <div className="track">
              <div
                className="fill"
                style={{ width: `${Math.min(100, Math.max(0, record.confidence * 100))}%` }}
              />
            </div>
            <span>{pct(record.confidence)}</span>
          </div>
        </td>
        <td>
          <div style={{ display: 'flex', gap: '4px', flexWrap: 'wrap' }}>
            {isIdle && (
              <span className="chip info">
                <span className="dot" />
                IDLE
              </span>
            )}
            {record.is_uncertain && !isIdle && (
              <span className="chip warning">
                <span className="dot" />
                UNCERTAIN
              </span>
            )}
            {!isIdle && !record.is_uncertain && (
              <span className="chip good">
                <span className="dot" />
                CONFIDENT
              </span>
            )}
          </div>
        </td>
        <td>{record.inference_micros.toLocaleString()} µs</td>
      </tr>

      {isExpanded && (
        <tr className="detail">
          <td colSpan={5}>
            <div style={{ marginBottom: '8px', color: 'var(--text-muted)', fontSize: '12px' }}>
              Probability Breakdown (ID #{record.id}, Sequence #{record.seq})
            </div>
            <div className="bars">
              {record.top?.map((cp, idx) => (
                <BarRow key={`${cp.label}-${idx}`} label={cp.label} prob={cp.prob} />
              ))}
              {record.other_prob > 0 && (
                <BarRow label="other" prob={record.other_prob} isOther />
              )}
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

function BarRow({
  label,
  prob,
  isOther = false,
}: {
  label: string;
  prob: number;
  isOther?: boolean;
}) {
  const percent = Math.min(100, Math.max(0, prob * 100));
  const isIdle = isIdleWord(label);
  const displayLabel = isIdle ? `${label} (Idle)` : label;

  return (
    <>
      <span className={`lbl${isOther || isIdle ? ' other' : ''}`} title={displayLabel}>
        {displayLabel}
      </span>
      <div className="track">
        <div
          className={`fill${isOther || isIdle ? ' other' : ''}`}
          style={{ width: `${percent}%` }}
        />
      </div>
      <span className="val">{pct(prob)}</span>
    </>
  );
}

/* =========================================================================
   2. AI Logs View
   ========================================================================= */
type LogEntry = {
  timestamp_ms: number;
  level: string;
  logger: string;
  message: string;
};

function LogsView() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [minLevel, setMinLevel] = useState<string>('');
  const [connected, setConnected] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);
  const [following, setFollowing] = useState<boolean>(true);

  const containerRef = useRef<HTMLDivElement | null>(null);
  const autoScrollRef = useRef<boolean>(true);
  const isProgrammaticScrollRef = useRef<boolean>(false);
  const incomingBufferRef = useRef<LogEntry[]>([]);

  function handleScroll() {
    if (isProgrammaticScrollRef.current) return;
    const el = containerRef.current;
    if (!el) return;
    const distanceToBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
    const isAtBottom = distanceToBottom <= 120;
    autoScrollRef.current = isAtBottom;
    if (isAtBottom !== following) {
      setFollowing(isAtBottom);
    }
  }

  useEffect(() => {
    const timer = setInterval(() => {
      if (incomingBufferRef.current.length === 0) return;
      const buffered = incomingBufferRef.current;
      incomingBufferRef.current = [];
      setLogs((prev) => {
        const next = [...prev, ...buffered];
        return next.length > 2000 ? next.slice(-2000) : next;
      });
    }, 100);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    incomingBufferRef.current = [];
    setError(null);

    const levelParam = minLevel ? minLevel.toLowerCase() : '';
    const url = `/api/v1/admin/logs${levelParam ? `?min_level=${encodeURIComponent(levelParam)}` : ''}`;
    const es = new EventSource(url);
    let receivedFirst = false;

    es.onopen = () => {
      setConnected(true);
      setError(null);
      if (!receivedFirst) {
        setLogs([]);
        incomingBufferRef.current = [];
        receivedFirst = true;
      }
    };

    es.onmessage = (event) => {
      try {
        const entry = JSON.parse(event.data) as LogEntry;
        incomingBufferRef.current.push(entry);
      } catch (err) {
        console.error('Failed to parse SSE log message:', err);
      }
    };

    es.onerror = () => {
      if (es.readyState === EventSource.CLOSED) {
        es.close();
        setConnected(false);
        setError('Connection closed — the server rejected the request. Check the log level parameter.');
      } else {
        setConnected(false);
      }
    };

    return () => {
      es.close();
      setConnected(false);
    };
  }, [minLevel]);

  useEffect(() => {
    if (autoScrollRef.current && containerRef.current) {
      isProgrammaticScrollRef.current = true;
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
      requestAnimationFrame(() => {
        if (containerRef.current) {
          containerRef.current.scrollTop = containerRef.current.scrollHeight;
        }
        setTimeout(() => {
          isProgrammaticScrollRef.current = false;
        }, 50);
      });
    }
  }, [logs]);

  function handleClear() {
    incomingBufferRef.current = [];
    setLogs([]);
  }

  function handleResumeFollow() {
    autoScrollRef.current = true;
    setFollowing(true);
    if (containerRef.current) {
      isProgrammaticScrollRef.current = true;
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
      setTimeout(() => {
        isProgrammaticScrollRef.current = false;
      }, 50);
    }
  }

  return (
    <div>
      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
        <div className="row" style={{ marginBottom: 0 }}>
          <div>
            <label className="field" style={{ marginBottom: 0 }}>
              <span>Minimum Level</span>
              <select value={minLevel} onChange={(e) => setMinLevel(e.target.value)}>
                <option value="">Server Default (Dev: debug, Prod: info)</option>
                <option value="DEBUG">DEBUG</option>
                <option value="INFO">INFO</option>
                <option value="WARNING">WARNING</option>
                <option value="ERROR">ERROR</option>
              </select>
            </label>
          </div>
          <button type="button" className="secondary" onClick={handleClear}>
            Clear Logs
          </button>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span className={`chip ${connected ? 'good' : 'warning'}`}>
            <span className="dot" />
            {connected ? 'STREAMING' : 'RECONNECTING'}
          </span>
          <span className={`chip ${following ? 'info' : 'warning'}`}>
            <span className="dot" />
            {following ? 'FOLLOWING LOGS' : 'SCROLLED UP'}
          </span>
          {!following && (
            <button
              type="button"
              className="secondary"
              onClick={handleResumeFollow}
            >
              Follow Bottom
            </button>
          )}
        </div>
      </div>

      {error && (
        <div className="notice error">
          Stream error: {error}
        </div>
      )}

      <div
        ref={containerRef}
        onScroll={handleScroll}
        className="logview"
        style={{ marginTop: '14px' }}
      >
        {logs.length === 0 ? (
          <div className="empty">Waiting for log events...</div>
        ) : (
          logs.map((entry, idx) => (
            <div key={`${entry.timestamp_ms}-${idx}`} className="logline">
              <span className="ts">[{formatTime(entry.timestamp_ms)}] </span>
              <span className={`lvl ${entry.level.toUpperCase()}`}>
                {entry.level.toUpperCase()}{' '}
              </span>
              <span className="logger">{entry.logger}: </span>
              <span>{entry.message}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

/* =========================================================================
   3. Upload View
   ========================================================================= */
function UploadView() {
  const [modelFile, setModelFile] = useState<File | null>(null);
  const [labelMapFile, setLabelMapFile] = useState<File | null>(null);
  const [preprocessFile, setPreprocessFile] = useState<File | null>(null);

  const [uploading, setUploading] = useState<boolean>(false);
  const [progress, setProgress] = useState<number>(0);
  const [result, setResult] = useState<UploadResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  function handleUploadSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!modelFile || !labelMapFile) {
      setError('Both model (.tflite) and label_map (.json) are required.');
      return;
    }

    setUploading(true);
    setProgress(0);
    setResult(null);
    setError(null);

    const fd = new FormData();
    fd.append('model', modelFile);
    fd.append('label_map', labelMapFile);
    if (preprocessFile) {
      fd.append('preprocess_config', preprocessFile);
    }

    uploadFormData('/api/v1/admin/model', fd, (pctVal) => {
      setProgress(pctVal);
    })
      .then((resData) => {
        setResult(resData);
      })
      .catch((err) => {
        setError(err instanceof Error ? err.message : String(err));
      })
      .finally(() => {
        setUploading(false);
      });
  }

  return (
    <div>
      <div className="card" style={{ maxWidth: '620px' }}>
        <h2>Hot-swap TSL Recognition Model</h2>
        <p style={{ color: 'var(--text-muted)', fontSize: '13px', marginTop: 0, marginBottom: '16px' }}>
          Upload new TSL recognition model artifacts to deploy them live in the Python inference worker.
        </p>

        <form onSubmit={handleUploadSubmit}>
          <label className="field">
            <span>Model File (.tflite) * Required</span>
            <input
              type="file"
              accept=".tflite"
              required
              onChange={(e) => setModelFile(e.target.files?.[0] ?? null)}
            />
          </label>

          <label className="field">
            <span>Label Map (.json) * Required</span>
            <input
              type="file"
              accept=".json"
              required
              onChange={(e) => setLabelMapFile(e.target.files?.[0] ?? null)}
            />
          </label>

          <label className="field">
            <span>Preprocess Config (.json) Optional</span>
            <input
              type="file"
              accept=".json"
              onChange={(e) => setPreprocessFile(e.target.files?.[0] ?? null)}
            />
          </label>

          {uploading && (
            <div style={{ margin: '14px 0' }}>
              <div style={{ fontSize: '12px', color: 'var(--text-secondary)', marginBottom: '4px' }}>
                Uploading artifacts... ({progress}%)
              </div>
              <progress value={progress} max={100} />
            </div>
          )}

          {error && (
            <div className="notice error">
              Upload rejected: {error}
            </div>
          )}

          {result && (
            <div className="notice success">
              <strong>Model hot-swapped successfully!</strong>
              <div style={{ marginTop: '6px' }}>
                Num Classes: {result.num_classes} &nbsp;|&nbsp; Sequence Len: {result.sequence_len} &nbsp;|&nbsp; Feature Dim: {result.feature_dim}
              </div>
            </div>
          )}

          <div style={{ marginTop: '16px' }}>
            <button type="submit" disabled={uploading || !modelFile || !labelMapFile}>
              {uploading ? 'Uploading...' : 'Upload & Deploy Model'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function uploadFormData(
  url: string,
  formData: FormData,
  onProgress: (pct: number) => void
): Promise<UploadResult> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        const percent = Math.round((event.loaded / event.total) * 100);
        onProgress(percent);
      }
    };

    xhr.onload = () => {
      let data: any;
      try {
        data = JSON.parse(xhr.responseText);
      } catch {
        data = null;
      }

      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(data as UploadResult);
      } else {
        let msg = `HTTP ${xhr.status}`;
        if (data && typeof data === 'object') {
          if (data.title) msg = data.title;
          if (data.detail) msg += `: ${data.detail}`;
        } else if (xhr.responseText) {
          msg = xhr.responseText;
        }
        reject(new Error(msg));
      }
    };

    xhr.onerror = () => {
      reject(new Error('Network error occurred during file upload.'));
    };

    xhr.send(formData);
  });
}

/* =========================================================================
   4. Settings View (Model Upload, Auto Clean Logs, Runtime Tuning)
   ========================================================================= */
function SettingsView() {
  const [status, setStatus] = useState<Status | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  const [idleFrames, setIdleFrames] = useState<string>('');
  const [idleMotionStd, setIdleMotionStd] = useState<string>('');
  const [autoCleanMax, setAutoCleanMax] = useState<string>('');
  const [savingSettings, setSavingSettings] = useState<boolean>(false);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  async function loadStatus(showSpinner = false) {
    if (showSpinner) setLoading(true);
    try {
      const res = await fetchStatus();
      setStatus(res);
      setError(null);
      if (res.tuning && idleFrames === '') {
        setIdleFrames(String(res.tuning.idle_min_frames_with_hands));
        setIdleMotionStd(String(res.tuning.idle_motion_std_threshold));
      }
      if (autoCleanMax === '') {
        setAutoCleanMax(String(res.auto_clean_max_predictions ?? 0));
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      if (showSpinner) setLoading(false);
    }
  }

  useEffect(() => {
    loadStatus(true);
    const interval = setInterval(() => loadStatus(false), 5000);
    return () => clearInterval(interval);
  }, []);

  async function handleSaveSettings(e: React.FormEvent) {
    e.preventDefault();
    setSavingSettings(true);
    setNotice(null);
    try {
      const f = parseInt(idleFrames, 10);
      const m = parseFloat(idleMotionStd);
      const cleanMax = parseInt(autoCleanMax, 10);

      const res = await putSettings({
        idle_min_frames_with_hands: isNaN(f) ? undefined : f,
        idle_motion_std_threshold: isNaN(m) ? undefined : m,
        auto_clean_max_predictions: isNaN(cleanMax) ? 0 : cleanMax,
      });

      setStatus((prev) => (prev ? {
        ...prev,
        tuning: res,
        auto_clean_max_predictions: res.auto_clean_max_predictions ?? (isNaN(cleanMax) ? 0 : cleanMax),
      } : prev));
      setNotice({ type: 'success', text: 'Settings updated successfully.' });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNotice({ type: 'error', text: `Failed to update settings: ${msg}` });
    } finally {
      setSavingSettings(false);
    }
  }

  const t: Tuning | undefined = status?.tuning;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      {/* 1. Hot-swap Model Upload Card */}
      <UploadView />

      {error && (
        <div className="notice error">
          Failed to fetch system status: {error}
        </div>
      )}

      {loading && !status ? (
        <div className="empty">Loading settings configuration...</div>
      ) : (
        <>
          <div className="grid">
            {/* 2. System & Tuning Settings Form */}
            <div className="card">
              <h2>TSL Model & Prediction Settings</h2>
              <p style={{ color: 'var(--text-muted)', fontSize: '13px', marginTop: 0, marginBottom: '16px' }}>
                Configure prediction log auto-cleaning limits and real-time AI inference bypass thresholds.
              </p>

              <form onSubmit={handleSaveSettings}>
                <div style={{ marginBottom: '20px', paddingBottom: '16px', borderBottom: '1px solid rgba(255,255,255,0.08)' }}>
                  <h3 style={{ fontSize: '14px', margin: '0 0 8px 0', color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: '6px' }}>
                    <span>🧹</span> Auto Clean Prediction Logs
                  </h3>
                  <label className="field">
                    <span>Max Prediction Logs Retained (X Predictions)</span>
                    <input
                      type="number"
                      step="1"
                      min="0"
                      value={autoCleanMax}
                      onChange={(e) => setAutoCleanMax(e.target.value)}
                      placeholder="e.g. 1000 (0 to disable)"
                    />
                    <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
                      Automatically deletes oldest prediction records when total entries exceed this threshold. Set to 0 to keep all records.
                    </small>
                  </label>
                  <div style={{ display: 'flex', gap: '6px', marginTop: '8px', flexWrap: 'wrap', alignItems: 'center' }}>
                    <span style={{ fontSize: '12px', color: 'var(--text-muted)' }}>Presets:</span>
                    {[0, 500, 1000, 5000, 10000].map((val) => (
                      <button
                        key={val}
                        type="button"
                        className="secondary"
                        style={{ padding: '2px 8px', fontSize: '11px', height: 'auto' }}
                        onClick={() => setAutoCleanMax(String(val))}
                      >
                        {val === 0 ? 'Disabled (0)' : val.toLocaleString()}
                      </button>
                    ))}
                  </div>
                </div>

                {t ? (
                  <>
                    <div style={{ marginBottom: '16px' }}>
                      <h3 style={{ fontSize: '14px', margin: '0 0 8px 0', color: 'var(--text-primary)', display: 'flex', alignItems: 'center', gap: '6px' }}>
                        <span>🖐️</span> Runtime Inference Bypass Thresholds
                      </h3>
                      <label className="field">
                        <span>Idle Min Frames With Hands</span>
                        <input
                          type="number"
                          step="1"
                          min="0"
                          value={idleFrames}
                          onChange={(e) => setIdleFrames(e.target.value)}
                        />
                        <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
                          Minimum hand-present frames required before running neural network inference.
                        </small>
                      </label>

                      <label className="field">
                        <span>Idle Motion Std Threshold</span>
                        <input
                          type="number"
                          step="0.0001"
                          min="0"
                          value={idleMotionStd}
                          onChange={(e) => setIdleMotionStd(e.target.value)}
                        />
                        <small style={{ color: 'var(--text-muted)', display: 'block', marginTop: '4px' }}>
                          Hand movement standard deviation threshold. Values below this mark hands as static/idle.
                        </small>
                      </label>
                    </div>

                    {notice && (
                      <div className={`notice ${notice.type}`} style={{ margin: '12px 0' }}>
                        {notice.text}
                      </div>
                    )}

                    <div style={{ marginTop: '16px' }}>
                      <button type="submit" disabled={savingSettings}>
                        {savingSettings ? 'Saving Settings...' : 'Save Settings'}
                      </button>
                    </div>
                  </>
                ) : (
                  <div className="empty" style={{ padding: '8px' }}>
                    Cannot configure runtime tuning while AI service is offline
                  </div>
                )}
              </form>
            </div>

            {/* 3. Active Model & System Summary Card */}
            <div className="card">
              <h2>Active Model Summary</h2>
              {t ? (
                <dl className="kv">
                  <dt>Model Loaded</dt>
                  <dd>
                    <span className={`chip ${t.model_loaded ? 'good' : 'warning'}`}>
                      <span className="dot" />
                      {t.model_loaded ? 'Yes' : 'No'}
                    </span>
                  </dd>
                  <dt>Num Classes</dt>
                  <dd>{t.num_classes}</dd>
                  <dt>Sequence Len</dt>
                  <dd>{t.sequence_len}</dd>
                  <dt>Feature Dim</dt>
                  <dd>{t.feature_dim}</dd>
                  <dt>Debug Mode</dt>
                  <dd>{t.debug_mode ? 'Enabled' : 'Disabled'}</dd>
                  <dt>Auto Clean Limit</dt>
                  <dd>
                    {status?.auto_clean_max_predictions && status.auto_clean_max_predictions > 0
                      ? `${status.auto_clean_max_predictions.toLocaleString()} predictions`
                      : 'Disabled'}
                  </dd>
                </dl>
              ) : (
                <div className="empty" style={{ padding: '8px' }}>
                  Model metadata unavailable
                </div>
              )}
            </div>
          </div>

          {/* 4. Parameter Documentation & Guide Card */}
          <div className="card">
            <h2>Parameter Documentation & Guide</h2>
            <div style={{ display: 'flex', flexDirection: 'column', gap: '16px', marginTop: '14px' }}>
              <div>
                <h3 style={{ fontSize: '15px', color: 'var(--text-primary)', margin: '0 0 6px 0', display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span>🧹</span> Prediction Log Auto-Clean (<code>auto_clean_max_predictions</code>)
                </h3>
                <p style={{ margin: 0, color: 'var(--text-secondary)', fontSize: '13px', lineHeight: '1.6' }}>
                  <strong>What it does:</strong> Maintains the prediction log database size by retaining at most <em>X</em> latest prediction entries.
                  <br />
                  <strong>Why it matters:</strong> Prevents SQLite database growth over extended real-time streaming sessions while preserving recent history for analysis. Old entries beyond <em>X</em> are pruned automatically on insertion or setting save. Set to 0 to retain all prediction history without limit.
                </p>
              </div>

              <div style={{ borderTop: '1px solid rgba(255,255,255,0.08)', paddingTop: '14px' }}>
                <h3 style={{ fontSize: '15px', color: 'var(--text-primary)', margin: '0 0 6px 0', display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span>🖐️</span> Idle Min Frames With Hands (<code>idle_min_frames_with_hands</code>)
                </h3>
                <p style={{ margin: 0, color: 'var(--text-secondary)', fontSize: '13px', lineHeight: '1.6' }}>
                  <strong>What it does:</strong> Defines the minimum count of frames in the sequence window where valid hand landmarks (non-zero coordinates) are detected.
                  <br />
                  <strong>Why it matters:</strong> If fewer hand frames are detected in the window than this minimum, the AI worker skips neural network inference completely and returns an <em>IDLE</em> status (confidence = 0.0). This saves CPU/GPU resources when the user is not actively displaying hands to the camera.
                  <br />
                  <strong>Default value:</strong> <code>6</code> frames.
                </p>
              </div>

              <div style={{ borderTop: '1px solid rgba(255,255,255,0.08)', paddingTop: '14px' }}>
                <h3 style={{ fontSize: '15px', color: 'var(--text-primary)', margin: '0 0 6px 0', display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span>📉</span> Idle Motion Std Threshold (<code>idle_motion_std_threshold</code>)
                </h3>
                <p style={{ margin: 0, color: 'var(--text-secondary)', fontSize: '13px', lineHeight: '1.6' }}>
                  <strong>What it does:</strong> Measures the spatial standard deviation (variance) of hand landmark coordinates over the temporal frame sequence window.
                  <br />
                  <strong>Why it matters:</strong> When a user holds their hands stationary (or rests them), the landmark standard deviation falls below this threshold. The engine identifies this as a static pose and bypasses inference with an <em>IDLE</em> result, preventing continuous false prediction triggers when hands are not moving.
                  <br />
                  <strong>Default value:</strong> <code>0.005</code>.
                </p>
              </div>

              <div style={{ borderTop: '1px solid rgba(255,255,255,0.08)', paddingTop: '14px' }}>
                <h3 style={{ fontSize: '15px', color: 'var(--text-primary)', margin: '0 0 6px 0', display: 'flex', alignItems: 'center', gap: '8px' }}>
                  <span>📱</span> Confidence Threshold Note
                </h3>
                <p style={{ margin: 0, color: 'var(--text-secondary)', fontSize: '13px', lineHeight: '1.6' }}>
                  <strong>Client-Side Evaluation:</strong> Confidence filtering has been moved to the Flutter mobile app client to allow local gesture responsiveness, customizable sensitivity, and per-exercise target thresholds. The server inference engine supplies full raw probability distributions so the Flutter client can make real-time UI decisions.
                </p>
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );
}


