'use client';

import { useEffect, useRef, useState } from 'react';
import { formatTime } from '../../lib/api';

type LogEntry = {
  timestamp_ms: number;
  level: string;
  logger: string;
  message: string;
};

export default function LogsPage() {
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

  // Batch incoming high-frequency logs (e.g. 3+ lines/frame) every 100ms
  // to avoid React rendering floods and false onScroll detachments.
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
    setLogs([]);
    incomingBufferRef.current = [];
    setError(null);

    const url = `/api/v1/admin/logs${minLevel ? `?min_level=${encodeURIComponent(minLevel)}` : ''}`;
    const es = new EventSource(url);

    es.onopen = () => {
      setConnected(true);
      setError(null);
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
      setConnected(false);
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
      <h1>AI Service Logs</h1>
      <p className="subtitle">Live Server-Sent Events stream from the Python gRPC AI service</p>

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
