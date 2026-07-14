'use client';

import { useEffect, useRef, useState, FormEvent } from 'react';
import {
  fetchAdminSigns,
  fetchSign,
  createSign,
  deleteSign,
  uploadSignRecording,
  LearnSign,
  KeypointFrame,
} from '../../lib/api';

export default function DictionaryPage() {
  const [signs, setSigns] = useState<LearnSign[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  // New-sign form.
  const [newWord, setNewWord] = useState('');
  const [newCategory, setNewCategory] = useState('');
  const [savingSign, setSavingSign] = useState(false);

  // The word currently being recorded for (null = recorder closed).
  const [recordingWord, setRecordingWord] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  // Avatar animation preview (null = closed). Frames are fetched on demand.
  const [previewWord, setPreviewWord] = useState<string | null>(null);
  const [previewFrames, setPreviewFrames] = useState<KeypointFrame[][] | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);

  async function load() {
    try {
      const s = await fetchAdminSigns();
      setSigns(s);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  function fail(prefix: string, err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    setNotice({ type: 'error', text: `${prefix}: ${msg}` });
  }

  async function handleCreateSign(e: FormEvent) {
    e.preventDefault();
    setSavingSign(true);
    setNotice(null);
    try {
      await createSign(newWord.trim(), newCategory.trim());
      setNotice({ type: 'success', text: `Sign "${newWord.trim()}" saved.` });
      setNewWord('');
      setNewCategory('');
      await load();
    } catch (err) {
      fail('Failed to save sign', err);
    } finally {
      setSavingSign(false);
    }
  }

  async function handleDelete(word: string) {
    setConfirmDelete(null);
    try {
      await deleteSign(word);
      setNotice({ type: 'success', text: `Sign "${word}" deleted.` });
      if (recordingWord === word) setRecordingWord(null);
      if (previewWord === word) closePreview();
      await load();
    } catch (err) {
      fail('Failed to delete sign', err);
    }
  }

  function closePreview() {
    setPreviewWord(null);
    setPreviewFrames(null);
  }

  // Toggle the avatar preview for a word, fetching its recorded frames on open.
  async function handleShowAnimation(word: string) {
    if (previewWord === word) {
      closePreview();
      return;
    }
    setPreviewWord(word);
    setPreviewFrames(null);
    setPreviewLoading(true);
    setNotice(null);
    try {
      const detail = await fetchSign(word);
      setPreviewFrames(detail.keypoint_frames ?? []);
    } catch (err) {
      fail('Failed to load animation', err);
      closePreview();
    } finally {
      setPreviewLoading(false);
    }
  }

  const withAnimation = signs.filter((s) => s.has_animation).length;

  return (
    <div>
      <h1>Dictionary</h1>
      <p className="subtitle">
        Build the recorded sign library: create a word, record it in-browser, and the backend extracts
        the keypoint frames the avatar plays back in the dictionary and AI conversation
      </p>

      {notice && <div className={`notice ${notice.type}`}>{notice.text}</div>}
      {error && <div className="notice error">Failed to load signs: {error}</div>}

      <div className="card" style={{ marginBottom: 20, maxWidth: 620 }}>
        <h2>New sign</h2>
        <form onSubmit={handleCreateSign}>
          <label className="field">
            <span>Word (shown in the app)</span>
            <input
              value={newWord}
              onChange={(e) => setNewWord(e.target.value)}
              placeholder="สวัสดี"
              required
            />
          </label>
          <label className="field">
            <span>Category</span>
            <input
              value={newCategory}
              onChange={(e) => setNewCategory(e.target.value)}
              placeholder="greetings"
            />
          </label>
          <button type="submit" disabled={savingSign || newWord.trim() === ''}>
            {savingSign ? 'Saving...' : 'Save sign'}
          </button>
        </form>
      </div>

      {recordingWord && (
        <div className="card" style={{ marginBottom: 20, maxWidth: 620 }}>
          <SignRecorder
            word={recordingWord}
            onUploaded={() => {
              setNotice({ type: 'success', text: `Animation saved for "${recordingWord}".` });
              setRecordingWord(null);
              load();
            }}
            onCancel={() => setRecordingWord(null)}
            onError={(text) => setNotice({ type: 'error', text })}
          />
        </div>
      )}

      {previewWord && (
        <div className="card" style={{ marginBottom: 20, maxWidth: 620 }}>
          <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
            <h2 style={{ margin: 0 }}>Animation: {previewWord}</h2>
            <button
              className="secondary"
              style={{ fontSize: 12, padding: '4px 10px' }}
              onClick={closePreview}
            >
              Close
            </button>
          </div>
          {previewLoading ? (
            <div className="empty">Loading animation…</div>
          ) : previewFrames && previewFrames.length > 0 ? (
            <div className="row" style={{ gap: 16, alignItems: 'center' }}>
              <AvatarPreview frames={previewFrames} />
              <p className="subtitle" style={{ margin: 0 }}>
                {previewFrames.length} frames · {previewFrames[0]?.length ?? 0} points/frame
                <br />
                Loops the recorded keypoints — the same animation the app avatar plays.
              </p>
            </div>
          ) : (
            <div className="empty">No animation data for this sign.</div>
          )}
        </div>
      )}

      <div className="row" style={{ marginBottom: 12 }}>
        <span className="chip info">
          <span className="dot" />
          {signs.length} sign{signs.length !== 1 ? 's' : ''} · {withAnimation} with animation
        </span>
      </div>

      {loading ? (
        <div className="empty">Loading signs...</div>
      ) : signs.length === 0 ? (
        <div className="empty">No signs yet — create the first one above.</div>
      ) : (
        <div className="tablewrap">
          <table>
            <thead>
              <tr>
                <th>Word</th>
                <th>Category</th>
                <th>Animation</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {signs.map((s) => (
                <tr key={s.word}>
                  <td className="word">{s.word}</td>
                  <td>{s.category || '—'}</td>
                  <td>
                    <span className={`chip ${s.has_animation ? 'info' : 'warning'}`}>
                      <span className="dot" />
                      {s.has_animation ? 'has animation' : 'no animation'}
                    </span>
                  </td>
                  <td>
                    <span className="row" style={{ gap: 6 }}>
                      {s.has_animation && (
                        <button
                          className="secondary"
                          style={{ fontSize: 12, padding: '4px 10px' }}
                          onClick={() => handleShowAnimation(s.word)}
                        >
                          {previewWord === s.word ? 'Hide animation' : 'Show animation'}
                        </button>
                      )}
                      <button
                        className="secondary"
                        style={{ fontSize: 12, padding: '4px 10px' }}
                        onClick={() => setRecordingWord(s.word)}
                      >
                        {s.has_animation ? 'Re-record' : 'Record'}
                      </button>
                      {confirmDelete === s.word ? (
                        <>
                          <button
                            className="secondary"
                            style={{ fontSize: 12, padding: '4px 10px' }}
                            onClick={() => handleDelete(s.word)}
                          >
                            Confirm
                          </button>
                          <button
                            className="secondary"
                            style={{ fontSize: 12, padding: '4px 10px' }}
                            onClick={() => setConfirmDelete(null)}
                          >
                            Cancel
                          </button>
                        </>
                      ) : (
                        <button
                          className="secondary"
                          style={{ fontSize: 12, padding: '4px 10px' }}
                          onClick={() => setConfirmDelete(s.word)}
                        >
                          Delete
                        </button>
                      )}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

type RecorderPhase = 'idle' | 'live' | 'recording' | 'recorded';

// SignRecorder owns a single webcam capture session: getUserMedia -> MediaRecorder
// -> preview -> upload. It stops the camera track and frees the object URL on
// unmount, so closing the panel (parent clears recordingWord) always releases it.
function SignRecorder({
  word,
  onUploaded,
  onCancel,
  onError,
}: {
  word: string;
  onUploaded: () => void;
  onCancel: () => void;
  onError: (msg: string) => void;
}) {
  const liveRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const blobRef = useRef<Blob | null>(null);
  const extRef = useRef<string>('webm');
  const urlRef = useRef<string | null>(null);

  const [phase, setPhase] = useState<RecorderPhase>('idle');
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);

  function stopStream() {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
  }

  function clearUrl() {
    if (urlRef.current) {
      URL.revokeObjectURL(urlRef.current);
      urlRef.current = null;
    }
  }

  // Release camera + preview URL when the panel closes for any reason.
  useEffect(() => {
    return () => {
      stopStream();
      clearUrl();
    };
  }, []);

  async function startCamera() {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
      streamRef.current = stream;
      if (liveRef.current) {
        liveRef.current.srcObject = stream;
        // play() can reject if the element is detached mid-await; that is harmless.
        liveRef.current.play().catch(() => {});
      }
      setPhase('live');
    } catch (err) {
      onError(err instanceof Error ? err.message : 'Camera access was denied.');
    }
  }

  // Pick the first MediaRecorder container the browser actually supports; the
  // Go extractor names the temp file with the matching extension.
  function pickMimeType(): { mimeType: string; ext: string } {
    const candidates = [
      { mimeType: 'video/webm;codecs=vp9', ext: 'webm' },
      { mimeType: 'video/webm;codecs=vp8', ext: 'webm' },
      { mimeType: 'video/webm', ext: 'webm' },
      { mimeType: 'video/mp4', ext: 'mp4' },
    ];
    for (const c of candidates) {
      if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(c.mimeType)) {
        return c;
      }
    }
    return { mimeType: '', ext: 'webm' };
  }

  function startRecording() {
    const stream = streamRef.current;
    if (!stream) return;
    clearUrl();
    setPreviewUrl(null);
    blobRef.current = null;
    chunksRef.current = [];

    const picked = pickMimeType();
    let recorder: MediaRecorder;
    try {
      recorder = picked.mimeType
        ? new MediaRecorder(stream, { mimeType: picked.mimeType })
        : new MediaRecorder(stream);
    } catch (err) {
      onError(err instanceof Error ? err.message : 'This browser cannot record video.');
      return;
    }
    recorder.ondataavailable = (e) => {
      if (e.data.size > 0) chunksRef.current.push(e.data);
    };
    recorder.onstop = () => {
      const type = recorder.mimeType || 'video/webm';
      const blob = new Blob(chunksRef.current, { type });
      blobRef.current = blob;
      extRef.current = type.includes('mp4') ? 'mp4' : 'webm';
      const url = URL.createObjectURL(blob);
      urlRef.current = url;
      setPreviewUrl(url);
      setPhase('recorded');
    };
    recorderRef.current = recorder;
    recorder.start();
    setPhase('recording');
  }

  function stopRecording() {
    recorderRef.current?.stop();
  }

  function reRecord() {
    clearUrl();
    setPreviewUrl(null);
    blobRef.current = null;
    setPhase('live');
  }

  async function upload() {
    const blob = blobRef.current;
    if (!blob) return;
    setUploading(true);
    try {
      await uploadSignRecording(word, blob, extRef.current);
      stopStream();
      clearUrl();
      onUploaded();
    } catch (err) {
      onError(err instanceof Error ? err.message : String(err));
    } finally {
      setUploading(false);
    }
  }

  return (
    <div>
      <h2 style={{ marginTop: 0 }}>Record sign: {word}</h2>
      <p className="subtitle" style={{ marginTop: 0 }}>
        Sign the word once, centered in frame. Keep the clip short (2–4 seconds).
      </p>

      <div
        style={{
          background: '#000',
          borderRadius: 8,
          overflow: 'hidden',
          marginBottom: 12,
          display: phase === 'recorded' ? 'none' : 'block',
        }}
      >
        <video
          ref={liveRef}
          autoPlay
          muted
          playsInline
          style={{ width: '100%', maxHeight: 320, display: 'block' }}
        />
      </div>

      {phase === 'recorded' && previewUrl && (
        <div style={{ background: '#000', borderRadius: 8, overflow: 'hidden', marginBottom: 12 }}>
          <video
            src={previewUrl}
            controls
            playsInline
            style={{ width: '100%', maxHeight: 320, display: 'block' }}
          />
        </div>
      )}

      <div className="row" style={{ gap: 8 }}>
        {phase === 'idle' && <button onClick={startCamera}>Start camera</button>}
        {phase === 'live' && <button onClick={startRecording}>● Record</button>}
        {phase === 'recording' && (
          <button onClick={stopRecording}>■ Stop</button>
        )}
        {phase === 'recording' && (
          <span className="chip warning">
            <span className="dot" />
            recording…
          </span>
        )}
        {phase === 'recorded' && (
          <>
            <button onClick={upload} disabled={uploading}>
              {uploading ? 'Extracting…' : 'Upload & extract'}
            </button>
            <button className="secondary" onClick={reRecord} disabled={uploading}>
              Re-record
            </button>
          </>
        )}
        <button className="secondary" type="button" onClick={onCancel} disabled={uploading}>
          Cancel
        </button>
      </div>
    </div>
  );
}

// Upper-body edges over the 7 pose points [nose, Lshoulder, Rshoulder, Lelbow,
// Relbow, Lwrist, Rwrist] — mirrors Flutter's _SignAvatarPainter so the admin
// preview matches what the app renders.
const POSE_CONNECTIONS: [number, number][] = [
  [1, 2],
  [1, 3],
  [3, 5],
  [2, 4],
  [4, 6],
];
const AVATAR_ACCENT = '#3987e5'; // --series-1
const AVATAR_LOOP_MS = 2400;

// Draw one keypoint frame (normalized 0..1 coords) as a skeletal figure.
function renderAvatarFrame(ctx: CanvasRenderingContext2D, points: KeypointFrame[], size: number) {
  ctx.clearRect(0, 0, size, size);
  ctx.fillStyle = '#121211'; // --surface-0
  ctx.fillRect(0, 0, size, size);
  if (points.length === 0) return;
  const px = (p: KeypointFrame) => p.x * size;
  const py = (p: KeypointFrame) => p.y * size;

  if (points.length >= 7) {
    // Bones: neck (nose -> shoulder midpoint) plus the arm/shoulder edges.
    ctx.strokeStyle = 'rgba(57,135,229,0.85)';
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(px(points[0]), py(points[0]));
    ctx.lineTo(((points[1].x + points[2].x) / 2) * size, ((points[1].y + points[2].y) / 2) * size);
    for (const [a, b] of POSE_CONNECTIONS) {
      ctx.moveTo(px(points[a]), py(points[a]));
      ctx.lineTo(px(points[b]), py(points[b]));
    }
    ctx.stroke();

    // Head circle at the nose.
    ctx.strokeStyle = AVATAR_ACCENT;
    ctx.lineWidth = 2.2;
    ctx.beginPath();
    ctx.arc(px(points[0]), py(points[0]), size * 0.075, 0, Math.PI * 2);
    ctx.stroke();

    // Joint nodes (shoulders, elbows, wrists).
    for (let i = 1; i < 7; i++) {
      ctx.beginPath();
      ctx.arc(px(points[i]), py(points[i]), 4, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.fill();
      ctx.strokeStyle = AVATAR_ACCENT;
      ctx.lineWidth = 2.2;
      ctx.stroke();
    }
    // Hand keypoints render as smaller dots.
    ctx.fillStyle = '#ffffff';
    for (let i = 7; i < points.length; i++) {
      ctx.beginPath();
      ctx.arc(px(points[i]), py(points[i]), 2.6, 0, Math.PI * 2);
      ctx.fill();
    }
  } else {
    // Unknown/sparse layout: plain dots.
    for (const p of points) {
      ctx.beginPath();
      ctx.arc(px(p), py(p), 5, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.fill();
      ctx.strokeStyle = AVATAR_ACCENT;
      ctx.lineWidth = 2.2;
      ctx.stroke();
    }
  }
}

// AvatarPreview loops the recorded keypoint frames on a canvas at ~the app's
// 2.4s cadence, cancelling the animation frame on unmount / frame change.
function AvatarPreview({ frames, size = 220 }: { frames: KeypointFrame[][]; size?: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx || frames.length === 0) return;
    const paintAt = (t: number) => {
      const idx = Math.min(Math.floor(t * frames.length), frames.length - 1);
      renderAvatarFrame(ctx, frames[idx], size);
    };
    // Paint frame 0 synchronously: requestAnimationFrame is paused while the
    // tab is hidden, so relying on it alone can leave the canvas blank.
    paintAt(0);
    const start = performance.now();
    let raf = 0;
    const tick = (now: number) => {
      paintAt(((now - start) % AVATAR_LOOP_MS) / AVATAR_LOOP_MS);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [frames, size]);
  return (
    <canvas
      ref={canvasRef}
      width={size}
      height={size}
      style={{ borderRadius: 8, border: '1px solid var(--border)', flexShrink: 0 }}
    />
  );
}
