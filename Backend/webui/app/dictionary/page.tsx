'use client';

import { useEffect, useRef, useState, FormEvent } from 'react';
import {
  fetchAdminSigns,
  fetchSign,
  createSign,
  updateSignCategory,
  deleteSign,
  uploadSignRecording,
  importSignFromThsl,
  reindexDictionaryFromLabelMap,
  isIdleWord,
  LearnSign,
  KeypointFrame,
} from '../../lib/api';

const COMMON_CATEGORIES = [
  'คำพื้นฐาน',
  'กิจวัตรและการกระทำ',
  'อาหารและเครื่องดื่ม',
  'ผู้คนและครอบครัว',
  'ร่างกาย',
  'อารมณ์ความรู้สึก',
  'สิ่งของและสถานที่',
  'สัตว์และธรรมชาติ',
  'วันและเดือน',
  'เวลา',
  'สี',
  'ตัวเลข',
  'คำถามและประโยค',
  'ทั่วไป',
  'imported',
];

export default function DictionaryPage() {
  const [signs, setSigns] = useState<LearnSign[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  // Category inline editing
  const [editingCategoryWord, setEditingCategoryWord] = useState<string | null>(null);
  const [editingCategoryValue, setEditingCategoryValue] = useState<string>('');
  const [savingCategoryWord, setSavingCategoryWord] = useState<string | null>(null);

  // Search & category filter
  const [searchQuery, setSearchQuery] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('');

  // New-sign form.
  const [newWord, setNewWord] = useState('');
  const [newCategory, setNewCategory] = useState('');
  const [savingSign, setSavingSign] = useState(false);

  // Import-thsl form.
  const [importUrl, setImportUrl] = useState('');
  const [importWord, setImportWord] = useState('');
  const [importCategory, setImportCategory] = useState('');
  const [importing, setImporting] = useState(false);

  // Reindex dictionary state
  const [reindexing, setReindexing] = useState(false);

  // The word currently being recorded/uploaded for (null = recorder closed).
  const [recorderModal, setRecorderModal] = useState<{ word: string; initialFile?: File } | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const jsonFileInputRef = useRef<HTMLInputElement>(null);
  const [uploadTargetWord, setUploadTargetWord] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

  // Avatar animation preview (null = closed). Frames are fetched on demand.
  const [previewWord, setPreviewWord] = useState<string | null>(null);
  const [previewFrames, setPreviewFrames] = useState<KeypointFrame[][] | null>(null);
  const [previewLoading, setPreviewLoading] = useState(false);

  async function load() {
    try {
      const s = await fetchAdminSigns();
      // Filter out idle gesture "ไม่ทำอะไรเลย" / "ไม่ทำไรเลย" so it never counts as a dictionary word
      const validSigns = s.filter((item) => !isIdleWord(item.word));
      setSigns(validSigns);
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

  async function handleReindexDefault() {
    setReindexing(true);
    setNotice(null);
    try {
      const res = await reindexDictionaryFromLabelMap();
      setNotice({
        type: 'success',
        text: `Dictionary reindexed with label_map: ${res.added} new words added (${res.total} total valid words, excluding idle gesture "ไม่ทำอะไรเลย").`,
      });
      await load();
    } catch (err) {
      fail('Failed to reindex dictionary', err);
    } finally {
      setReindexing(false);
    }
  }

  async function handleCustomJsonReindex(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setReindexing(true);
    setNotice(null);
    try {
      const text = await file.text();
      const rawMap = JSON.parse(text) as Record<string, number | string>;
      const customMap: Record<string, string> = {};
      for (const key of Object.keys(rawMap)) {
        if (!isIdleWord(key)) {
          customMap[key.trim()] = 'ทั่วไป';
        }
      }
      const res = await reindexDictionaryFromLabelMap(customMap);
      setNotice({
        type: 'success',
        text: `Custom label_map reindexed: ${res.added} new words added (${res.total} total valid words indexed, idle gesture excluded).`,
      });
      await load();
    } catch (err) {
      fail('Failed to reindex from uploaded JSON', err);
    } finally {
      setReindexing(false);
      if (jsonFileInputRef.current) jsonFileInputRef.current.value = '';
    }
  }

  async function handleCreateSign(e: FormEvent) {
    e.preventDefault();
    const word = newWord.trim();
    if (isIdleWord(word)) {
      setNotice({ type: 'error', text: '"ไม่ทำอะไรเลย" / Idle gesture cannot be added as a dictionary word.' });
      return;
    }
    setSavingSign(true);
    setNotice(null);
    try {
      await createSign(word, newCategory.trim());
      setNotice({ type: 'success', text: `Sign "${word}" saved.` });
      setNewWord('');
      setNewCategory('');
      await load();
    } catch (err) {
      fail('Failed to save sign', err);
    } finally {
      setSavingSign(false);
    }
  }

  async function handleImportThsl(e: FormEvent) {
    e.preventDefault();
    setImporting(true);
    setNotice(null);
    try {
      const res = await importSignFromThsl(importUrl.trim(), importWord.trim(), importCategory.trim());
      setNotice({ type: 'success', text: `Imported sign "${res.word}" from th-sl.com.` });
      setImportUrl('');
      setImportWord('');
      setImportCategory('');
      await load();
    } catch (err) {
      fail('Failed to import from th-sl.com', err);
    } finally {
      setImporting(false);
    }
  }

  async function handleDelete(word: string) {
    setConfirmDelete(null);
    try {
      await deleteSign(word);
      setNotice({ type: 'success', text: `Sign "${word}" deleted.` });
      if (recorderModal?.word === word) setRecorderModal(null);
      if (previewWord === word) closePreview();
      await load();
    } catch (err) {
      fail('Failed to delete sign', err);
    }
  }

  async function handleSaveCategory(word: string) {
    const cat = editingCategoryValue.trim();
    setSavingCategoryWord(word);
    setNotice(null);
    try {
      await updateSignCategory(word, cat);
      setSigns((prev) =>
        prev.map((item) => (item.word === word ? { ...item, category: cat } : item))
      );
      setNotice({ type: 'success', text: `Updated category for "${word}" to "${cat || '—'}".` });
      setEditingCategoryWord(null);
    } catch (err) {
      fail('Failed to update category', err);
    } finally {
      setSavingCategoryWord(null);
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

  const categoriesList = Array.from(
    new Set(signs.map((s) => s.category?.trim() || '—'))
  ).sort();

  const filteredSigns = signs.filter((s) => {
    const catText = s.category?.trim() || '—';
    const matchesSearch =
      searchQuery.trim() === '' ||
      s.word.toLowerCase().includes(searchQuery.toLowerCase()) ||
      catText.toLowerCase().includes(searchQuery.toLowerCase());
    const matchesCat = categoryFilter === '' || catText === categoryFilter;
    return matchesSearch && matchesCat;
  });

  return (
    <div>
      <datalist id="category-suggestions">
        {COMMON_CATEGORIES.map((cat) => (
          <option key={cat} value={cat} />
        ))}
      </datalist>

      <h1>Dictionary</h1>
      <p className="subtitle">
        Build the recorded sign library: reindex label map, import from th-sl.com, record in-browser, or upload video files.
      </p>

      {notice && <div className={`notice ${notice.type}`}>{notice.text}</div>}
      {error && <div className="notice error">Failed to load signs: {error}</div>}

      {/* Reindex Card */}
      <div className="card" style={{ marginBottom: 20 }}>
        <h2>Reindex Vocabulary from Label Map (220-class map)</h2>
        <p className="subtitle" style={{ marginTop: 0 }}>
          Automatically index all 219 dictionary words from <code>label_map (1).json</code> into the dictionary database.
          Idle gesture <code>ไม่ทำอะไรเลย</code> (Class 217) is automatically excluded from word counts.
        </p>
        <div className="row" style={{ gap: 10, flexWrap: 'wrap' }}>
          <button type="button" onClick={handleReindexDefault} disabled={reindexing}>
            {reindexing ? 'Reindexing Vocabulary...' : '⚡ Reindex 219 Words from label_map (1).json'}
          </button>
          <button
            type="button"
            className="secondary"
            onClick={() => jsonFileInputRef.current?.click()}
            disabled={reindexing}
          >
            Upload Custom label_map.json
          </button>
          <input
            type="file"
            ref={jsonFileInputRef}
            accept=".json"
            style={{ display: 'none' }}
            onChange={handleCustomJsonReindex}
          />
        </div>
      </div>

      <div className="row" style={{ gap: 20, marginBottom: 20, flexWrap: 'wrap', alignItems: 'flex-start' }}>
        <div className="card" style={{ flex: '1 1 300px', maxWidth: 620, margin: 0 }}>
          <h2>Import from th-sl.com</h2>
          <form onSubmit={handleImportThsl}>
            <label className="field">
              <span>th-sl.com Link</span>
              <input
                type="url"
                value={importUrl}
                onChange={(e) => setImportUrl(e.target.value)}
                placeholder="https://www.th-sl.com/75993/"
                required
              />
            </label>
            <label className="field">
              <span>Word (optional - auto-detected if blank)</span>
              <input
                value={importWord}
                onChange={(e) => setImportWord(e.target.value)}
                placeholder="e.g. ว่าไง"
              />
            </label>
            <label className="field">
              <span>Category (optional)</span>
              <input
                value={importCategory}
                onChange={(e) => setImportCategory(e.target.value)}
                placeholder="e.g. greetings"
              />
            </label>
            <button type="submit" disabled={importing || importUrl.trim() === ''}>
              {importing ? 'Importing & Extracting...' : 'Import Sign from th-sl.com'}
            </button>
          </form>
        </div>

        <div className="card" style={{ flex: '1 1 300px', maxWidth: 620, margin: 0 }}>
          <h2>New sign (Manual)</h2>
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
      </div>

      <div className="row" style={{ marginBottom: 12, gap: 8, alignItems: 'center' }}>
        <span className="chip info">
          <span className="dot" />
          {filteredSigns.length} / {signs.length} sign{signs.length !== 1 ? 's' : ''} · {withAnimation} with animation
        </span>
        <span className="chip good">
          <span className="dot" />
          Idle gesture "ไม่ทำอะไรเลย" excluded from word count
        </span>
      </div>

      <div className="row" style={{ marginBottom: 16, gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
        <input
          type="text"
          placeholder="🔍 Search word or category..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          style={{ maxWidth: 260 }}
        />
        <select
          value={categoryFilter}
          onChange={(e) => setCategoryFilter(e.target.value)}
          style={{ maxWidth: 240 }}
        >
          <option value="">All Categories ({categoriesList.length})</option>
          {categoriesList.map((cat) => (
            <option key={cat} value={cat}>
              {cat} ({signs.filter((s) => (s.category?.trim() || '—') === cat).length})
            </option>
          ))}
        </select>
        {(searchQuery || categoryFilter) && (
          <button
            type="button"
            className="secondary"
            style={{ fontSize: 12, padding: '6px 12px' }}
            onClick={() => {
              setSearchQuery('');
              setCategoryFilter('');
            }}
          >
            Clear filters
          </button>
        )}
      </div>

      {loading ? (
        <div className="empty">Loading signs...</div>
      ) : signs.length === 0 ? (
        <div className="empty">No signs yet — reindex vocabulary or create the first sign above.</div>
      ) : filteredSigns.length === 0 ? (
        <div className="empty">No signs match the search/filter criteria.</div>
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
              {filteredSigns.map((s) => (
                <tr key={s.word}>
                  <td className="word">{s.word}</td>
                  <td>
                    {editingCategoryWord === s.word ? (
                      <span className="row" style={{ gap: 4, margin: 0, alignItems: 'center', flexWrap: 'nowrap' }}>
                        <input
                          type="text"
                          list="category-suggestions"
                          value={editingCategoryValue}
                          onChange={(e) => setEditingCategoryValue(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') handleSaveCategory(s.word);
                            if (e.key === 'Escape') setEditingCategoryWord(null);
                          }}
                          autoFocus
                          disabled={savingCategoryWord === s.word}
                          placeholder="Category"
                          style={{
                            padding: '4px 8px',
                            fontSize: 13,
                            maxWidth: 160,
                          }}
                        />
                        <button
                          type="button"
                          style={{ fontSize: 11, padding: '4px 8px' }}
                          disabled={savingCategoryWord === s.word}
                          onClick={() => handleSaveCategory(s.word)}
                        >
                          {savingCategoryWord === s.word ? '...' : 'Save'}
                        </button>
                        <button
                          type="button"
                          className="secondary"
                          style={{ fontSize: 11, padding: '4px 8px' }}
                          disabled={savingCategoryWord === s.word}
                          onClick={() => setEditingCategoryWord(null)}
                        >
                          Cancel
                        </button>
                      </span>
                    ) : (
                      <span className="row" style={{ gap: 6, margin: 0, alignItems: 'center' }}>
                        <span>{s.category || '—'}</span>
                        <button
                          type="button"
                          className="secondary"
                          style={{ fontSize: 11, padding: '2px 6px', cursor: 'pointer' }}
                          onClick={() => {
                            setEditingCategoryWord(s.word);
                            setEditingCategoryValue(s.category || '');
                          }}
                          title="Edit category"
                        >
                          ✏️ Edit
                        </button>
                      </span>
                    )}
                  </td>
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
                        onClick={() => setRecorderModal({ word: s.word })}
                      >
                        {s.has_animation ? 'Re-record' : 'Record'}
                      </button>
                      <button
                        className="secondary"
                        style={{ fontSize: 12, padding: '4px 10px' }}
                        onClick={() => {
                          setUploadTargetWord(s.word);
                          fileInputRef.current?.click();
                        }}
                      >
                        Upload video
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

      <input
        type="file"
        ref={fileInputRef}
        accept="video/*,video/webm,video/mp4"
        style={{ display: 'none' }}
        onChange={(e) => {
          const file = e.target.files?.[0];
          if (file && uploadTargetWord) {
            setRecorderModal({ word: uploadTargetWord, initialFile: file });
          }
          if (fileInputRef.current) fileInputRef.current.value = '';
        }}
      />

      {recorderModal && (
        <div
          style={{
            position: 'fixed',
            inset: 0,
            backgroundColor: 'rgba(0, 0, 0, 0.75)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
            padding: 20,
          }}
          onClick={(e) => {
            if (e.target === e.currentTarget) setRecorderModal(null);
          }}
        >
          <div
            className="card"
            style={{
              maxWidth: 620,
              width: '100%',
              maxHeight: '90vh',
              overflow: 'auto',
              margin: 0,
              boxShadow: '0 8px 32px rgba(0, 0, 0, 0.5)',
            }}
          >
            <SignRecorder
              word={recorderModal.word}
              initialFile={recorderModal.initialFile}
              onUploaded={() => {
                setNotice({ type: 'success', text: `Animation saved for "${recorderModal.word}".` });
                setRecorderModal(null);
                load();
              }}
              onCancel={() => setRecorderModal(null)}
              onError={(text) => setNotice({ type: 'error', text })}
            />
          </div>
        </div>
      )}

      {previewWord && (
        <div
          style={{
            position: 'fixed',
            inset: 0,
            backgroundColor: 'rgba(0, 0, 0, 0.75)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            zIndex: 1000,
            padding: 20,
          }}
          onClick={(e) => {
            if (e.target === e.currentTarget) closePreview();
          }}
        >
          <div
            className="card"
            style={{
              maxWidth: 620,
              width: '100%',
              maxHeight: '90vh',
              overflow: 'auto',
              margin: 0,
              boxShadow: '0 8px 32px rgba(0, 0, 0, 0.5)',
            }}
          >
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
              <div className="row" style={{ gap: 16, alignItems: 'center', flexWrap: 'wrap' }}>
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
  initialFile,
  onUploaded,
  onCancel,
  onError,
}: {
  word: string;
  initialFile?: File;
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
  const localFileInputRef = useRef<HTMLInputElement>(null);

  const [phase, setPhase] = useState<RecorderPhase>(initialFile ? 'recorded' : 'idle');
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

  // If an initial file was passed (via Upload button), prepopulate blob and preview.
  useEffect(() => {
    if (initialFile) {
      stopStream();
      clearUrl();
      blobRef.current = initialFile;
      const ext = initialFile.name.split('.').pop()?.toLowerCase() || 'webm';
      extRef.current = ext === 'mp4' ? 'mp4' : 'webm';
      const url = URL.createObjectURL(initialFile);
      urlRef.current = url;
      setPreviewUrl(url);
      setPhase('recorded');
    }
  }, [initialFile]);

  function handleLocalFilePick(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    stopStream();
    clearUrl();
    blobRef.current = file;
    const ext = file.name.split('.').pop()?.toLowerCase() || 'webm';
    extRef.current = ext === 'mp4' ? 'mp4' : 'webm';
    const url = URL.createObjectURL(file);
    urlRef.current = url;
    setPreviewUrl(url);
    setPhase('recorded');
    if (localFileInputRef.current) localFileInputRef.current.value = '';
  }

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

      <input
        type="file"
        ref={localFileInputRef}
        accept="video/*,video/webm,video/mp4"
        style={{ display: 'none' }}
        onChange={handleLocalFilePick}
      />
      <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
        {phase === 'idle' && (
          <>
            <button onClick={startCamera}>Start camera</button>
            <button
              className="secondary"
              type="button"
              onClick={() => localFileInputRef.current?.click()}
            >
              Upload video file
            </button>
          </>
        )}
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
            <button
              className="secondary"
              type="button"
              onClick={() => localFileInputRef.current?.click()}
              disabled={uploading}
            >
              Pick another file
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
