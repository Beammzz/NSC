'use client';

import { useEffect, useState } from 'react';
import {
  clearPredictions,
  fetchPredictions,
  formatTime,
  pct,
  PredictionRecord,
  PredictionsPage,
} from '../../lib/api';

const LIMIT = 25;

export default function PredictionsBrowserPage() {
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
      <h1>Predictions</h1>
      <p className="subtitle">Browse and analyze logged sign language predictions and class probability distributions</p>

      <div className="row" style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
        <form onSubmit={handleFilterSubmit} className="row" style={{ marginBottom: 0 }}>
          <div>
            <label className="field" style={{ marginBottom: 0 }}>
              <span>Filter by Word</span>
              <input
                type="text"
                placeholder="e.g.สวัสดี"
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
  return (
    <>
      <tr className="expandable" onClick={onToggle}>
        <td>{formatTime(record.created_ms)}</td>
        <td className="word">{record.word || '—'}</td>
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
            {record.is_idle && (
              <span className="chip info">
                <span className="dot" />
                IDLE
              </span>
            )}
            {record.is_uncertain && (
              <span className="chip warning">
                <span className="dot" />
                UNCERTAIN
              </span>
            )}
            {!record.is_idle && !record.is_uncertain && (
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
  return (
    <>
      <span className={`lbl${isOther ? ' other' : ''}`} title={label}>
        {label}
      </span>
      <div className="track">
        <div
          className={`fill${isOther ? ' other' : ''}`}
          style={{ width: `${percent}%` }}
        />
      </div>
      <span className="val">{pct(prob)}</span>
    </>
  );
}
