'use client';

import { Suspense, useEffect, useRef, useState, FormEvent } from 'react';
import { useSearchParams } from 'next/navigation';
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

type TabType = 'dictionary' | 'settings';

export default function DictionaryPageWrapper() {
  return (
    <Suspense fallback={<div className="empty">Loading Dictionary...</div>}>
      <DictionaryPage />
    </Suspense>
  );
}

function DictionaryPage() {
  const searchParams = useSearchParams();
  const rawTab = searchParams.get('tab');
  let initialTab: TabType = 'dictionary';
  if (rawTab === 'settings') {
    initialTab = 'settings';
  }
  const [activeTab, setActiveTab] = useState<TabType>(initialTab);

  useEffect(() => {
    const raw = searchParams.get('tab');
    if (raw === 'settings') {
      setActiveTab('settings');
    } else if (raw === 'dictionary' || raw === 'words') {
      setActiveTab('dictionary');
    }
  }, [searchParams]);

  const switchTab = (tab: TabType) => {
    setActiveTab(tab);
    const newUrl = new URL(window.location.href);
    newUrl.searchParams.set('tab', tab);
    window.history.replaceState(null, '', newUrl.toString());
  };

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
        Manage Thai Sign Language dictionary words, import signs, record animations, and configure dictionary settings
      </p>

      <div className="tab-bar">
        <button
          type="button"
          className={`tab-btn ${activeTab === 'dictionary' ? 'active' : ''}`}
          onClick={() => switchTab('dictionary')}
        >
          Dictionary Words
        </button>
        <button
          type="button"
          className={`tab-btn ${activeTab === 'settings' ? 'active' : ''}`}
          onClick={() => switchTab('settings')}
        >
          Settings
        </button>
      </div>

      {notice && <div className={`notice ${notice.type}`}>{notice.text}</div>}
      {error && <div className="notice error">Failed to load signs: {error}</div>}

      {activeTab === 'dictionary' && (
        <>
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
        </>
      )}

      {activeTab === 'settings' && (
        <div>
          <div className="card" style={{ maxWidth: 620 }}>
            <h2>Dictionary Settings & Label Map</h2>
            <p style={{ color: 'var(--text-muted)', fontSize: '13px', marginTop: 0, marginBottom: '16px' }}>
              Upload a custom <code>label_map.json</code> file to reindex vocabulary words into the dictionary database.
              Idle gesture <code>ไม่ทำอะไรเลย</code> (Class 217) is automatically excluded from word counts.
            </p>
            <div className="row" style={{ gap: 10, flexWrap: 'wrap', marginBottom: 0 }}>
              <button
                type="button"
                onClick={() => jsonFileInputRef.current?.click()}
                disabled={reindexing}
              >
                {reindexing ? 'Reindexing Vocabulary...' : 'Upload Custom label_map.json'}
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

// Cartoon avatar renderer — mirrors Flutter's _SignAvatarPainter (cartoon
// style) so the admin preview matches what the app renders. Frames carry the
// 7 upper-body pose points [nose, Lshoulder, Rshoulder, Lelbow, Relbow,
// Lwrist, Rwrist] followed by 21 MediaPipe landmarks per detected hand.
const AVATAR_ACCENT = '#3987e5'; // --series-1
const AVATAR_LOOP_MS = 2400;
const HAND_POINTS = 21;
// Fingers start at their knuckle, not the wrist: chains through the palm would
// pile on top of each other and read as one blob. The palm polygon covers the
// bases.
const FINGER_CHAINS = [
  [1, 2, 3, 4],
  [5, 6, 7, 8],
  [9, 10, 11, 12],
  [13, 14, 15, 16],
  [17, 18, 19, 20],
];
const PALM_OUTLINE = [0, 1, 5, 9, 13, 17];
// The figure carries its own dark outline, so this fixed palette reads on the
// dark card background.
const SKIN = '#f3c9a2';
const SKIN_SHADE = '#e0ae83';
const OUTLINE = '#2a2e3a';
const HAIR = '#3b2a24';
const BLUSH = 'rgba(232,116,107,0.33)';

type Vec = { x: number; y: number };

const dist = (a: Vec, b: Vec) => Math.hypot(a.x - b.x, a.y - b.y);
const unit = (v: Vec, fallback: Vec): Vec => {
  const len = Math.hypot(v.x, v.y);
  return len < 1e-6 ? fallback : { x: v.x / len, y: v.y / len };
};
const step = (p: Vec, dir: Vec, k: number): Vec => ({ x: p.x + dir.x * k, y: p.y + dir.y * k });

// Uniform scale + offset placing the whole clip inside the canvas. Recorded
// coordinates span the camera frame, so the raw figure runs off the edges.
// Measured over EVERY frame so the figure holds still while the clip plays.
function viewFit(frames: KeypointFrame[][], size: number) {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  let shoulderW = 0;
  // The synthesized torso hangs below the recorded points; nothing in the data
  // marks where it ends, so reserve room for it.
  let torsoBottom = -Infinity;
  for (const frame of frames) {
    for (const p of frame) {
      minX = Math.min(minX, p.x);
      maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y);
      maxY = Math.max(maxY, p.y);
    }
    if (frame.length < 7) continue;
    const w = dist(frame[1], frame[2]);
    shoulderW = Math.max(shoulderW, w);
    torsoBottom = Math.max(torsoBottom, (frame[1].y + frame[2].y) / 2 + w * 1.5);
  }
  if (!Number.isFinite(minX) || maxX <= minX) return { scale: size, dx: 0, dy: 0 };
  if (shoulderW <= 0) shoulderW = maxX - minX;
  if (!Number.isFinite(torsoBottom)) torsoBottom = maxY;

  // Head, torso sides and limb thickness all live outside the landmarks.
  const pad = shoulderW * 0.62;
  minX -= pad;
  maxX += pad;
  minY -= pad;
  maxY = Math.max(maxY + pad * 0.4, torsoBottom);

  const boxW = Math.max(maxX - minX, 1e-6);
  const boxH = Math.max(maxY - minY, 1e-6);
  const scale = Math.min(size / boxW, size / boxH);
  return {
    scale,
    dx: (size - boxW * scale) / 2 - minX * scale,
    dy: (size - boxH * scale) / 2 - minY * scale,
  };
}

// Splits a frame's trailing landmarks into 21-point hand blocks. Frames whose
// tail is not a whole number of hands yield none.
function handBlocks(frame: KeypointFrame[]): KeypointFrame[][] {
  const extra = frame.length - 7;
  if (extra <= 0 || extra % HAND_POINTS !== 0) return [];
  const blocks: KeypointFrame[][] = [];
  for (let i = 7; i + HAND_POINTS <= frame.length; i += HAND_POINTS) {
    blocks.push(frame.slice(i, i + HAND_POINTS));
  }
  return blocks;
}

// Maps a frame's hand blocks onto its two pose wrists — slot 0 belongs to pose
// point 5, slot 1 to pose point 6. MediaPipe emits hands in detection order,
// not left/right order, so the pairing is chosen by wrist distance.
function assignHands(frame: KeypointFrame[]): (KeypointFrame[] | null)[] {
  const result: (KeypointFrame[] | null)[] = [null, null];
  const blocks = handBlocks(frame);
  if (blocks.length === 0) return result;
  const wrists = [frame[5], frame[6]];
  if (blocks.length === 1) {
    const block = blocks[0];
    const slot = dist(block[0], wrists[0]) <= dist(block[0], wrists[1]) ? 0 : 1;
    result[slot] = block;
    return result;
  }
  const [a, b] = blocks;
  const straight = dist(a[0], wrists[0]) + dist(b[0], wrists[1]);
  const swapped = dist(a[0], wrists[1]) + dist(b[0], wrists[0]);
  result[0] = straight <= swapped ? a : b;
  result[1] = straight <= swapped ? b : a;
  return result;
}

// Hands to draw for frame [index]. Roughly half of the recorded frames carry
// no hand landmarks at all (detection drops out), so a wrist without data this
// frame reuses the most recently seen hand, shifted so its wrist landmark sits
// on the current wrist point. The search wraps, so frame 0 inherits the tail.
function handsForFrame(frames: KeypointFrame[][], index: number): (KeypointFrame[] | null)[] {
  const current = frames[index];
  const hands = assignHands(current);
  for (let slot = 0; slot < 2; slot++) {
    if (hands[slot] !== null) continue;
    for (let back = 1; back <= frames.length; back++) {
      const past = frames[(((index - back) % frames.length) + frames.length) % frames.length];
      if (past.length < 7) continue;
      const held = assignHands(past)[slot];
      if (held === null) continue;
      const wrist = current[5 + slot];
      const dx = wrist.x - held[0].x;
      const dy = wrist.y - held[0].y;
      hands[slot] = held.map((p) => ({ ...p, x: p.x + dx, y: p.y + dy }));
      break;
    }
  }
  return hands;
}

// Draw the frame at [index] of [frames] as a cartoon signing figure.
function renderAvatarFrame(ctx: CanvasRenderingContext2D, frames: KeypointFrame[][], index: number, size: number) {
  ctx.clearRect(0, 0, size, size);
  ctx.fillStyle = '#121211'; // --surface-0
  ctx.fillRect(0, 0, size, size);
  const points = frames[index] ?? [];
  if (points.length === 0) return;

  const fit = viewFit(frames, size);
  const P = (p: KeypointFrame): Vec => ({ x: p.x * fit.scale + fit.dx, y: p.y * fit.scale + fit.dy });
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';

  if (points.length < 7) {
    // Unknown/sparse layout (e.g. the 2-point server stub): plain dots.
    for (const p of points) {
      const c = P(p);
      ctx.beginPath();
      ctx.arc(c.x, c.y, 5, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.fill();
      ctx.strokeStyle = AVATAR_ACCENT;
      ctx.lineWidth = 2.2;
      ctx.stroke();
    }
    return;
  }

  const nose = P(points[0]);
  const lSh = P(points[1]);
  const rSh = P(points[2]);
  const lEl = P(points[3]);
  const rEl = P(points[4]);
  const lWr = P(points[5]);
  const rWr = P(points[6]);
  const mid = { x: (lSh.x + rSh.x) / 2, y: (lSh.y + rSh.y) / 2 };
  // Every proportion below is a multiple of shoulder width, so the figure
  // keeps its build whoever was recorded and however close they stood.
  let shoulderW = dist(lSh, rSh);
  if (shoulderW < fit.scale * 0.05) shoulderW = fit.scale * 0.3;
  const down = unit({ x: mid.x - nose.x, y: mid.y - nose.y }, { x: 0, y: 1 });
  const side = unit({ x: lSh.x - rSh.x, y: lSh.y - rSh.y }, { x: 1, y: 0 });
  const outlineW = shoulderW * 0.075;
  const headR = shoulderW * 0.46;
  const headC = step(nose, down, -headR * 0.22);

  const line = (a: Vec, b: Vec, color: string, width: number) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.stroke();
  };
  const chain = (pts: Vec[], color: string, width: number) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.moveTo(pts[0].x, pts[0].y);
    for (const p of pts.slice(1)) ctx.lineTo(p.x, p.y);
    ctx.stroke();
  };

  // Neck first: torso and head both overlap it.
  const neckW = shoulderW * 0.3;
  line(headC, mid, OUTLINE, neckW + outlineW);
  line(headC, mid, SKIN_SHADE, neckW);

  // Torso: a rounded shirt from the shoulder line down to synthesized hips
  // (the recording has no hip landmarks).
  const torsoTop = step(mid, down, shoulderW * 0.02);
  const hipMid = step(mid, down, shoulderW * 1.2);
  const halfTop = shoulderW * 0.6;
  const halfHip = shoulderW * 0.48;
  const bulge = (sign: number) =>
    step(step(torsoTop, down, shoulderW * 0.6), side, sign * halfTop * 1.05);
  ctx.beginPath();
  ctx.moveTo(step(torsoTop, side, halfTop).x, step(torsoTop, side, halfTop).y);
  ctx.quadraticCurveTo(
    bulge(1).x,
    bulge(1).y,
    step(hipMid, side, halfHip).x,
    step(hipMid, side, halfHip).y,
  );
  ctx.quadraticCurveTo(
    step(hipMid, down, shoulderW * 0.22).x,
    step(hipMid, down, shoulderW * 0.22).y,
    step(hipMid, side, -halfHip).x,
    step(hipMid, side, -halfHip).y,
  );
  ctx.quadraticCurveTo(
    bulge(-1).x,
    bulge(-1).y,
    step(torsoTop, side, -halfTop).x,
    step(torsoTop, side, -halfTop).y,
  );
  ctx.quadraticCurveTo(
    step(torsoTop, down, -shoulderW * 0.12).x,
    step(torsoTop, down, -shoulderW * 0.12).y,
    step(torsoTop, side, halfTop).x,
    step(torsoTop, side, halfTop).y,
  );
  ctx.closePath();
  ctx.fillStyle = AVATAR_ACCENT;
  ctx.fill();
  ctx.strokeStyle = OUTLINE;
  ctx.lineWidth = outlineW;
  ctx.stroke();

  // Arms: sleeved upper arm, bare forearm, both driven by the recorded elbow
  // and wrist points. Outlines go down first so one segment's fill never cuts
  // into the next segment's outline.
  const arms: Vec[][] = [
    [lSh, lEl, lWr],
    [rSh, rEl, rWr],
  ];
  const upperW = shoulderW * 0.3;
  const foreW = shoulderW * 0.24;
  for (const arm of arms) chain(arm, OUTLINE, upperW + outlineW);
  for (const arm of arms) {
    line(arm[0], arm[1], AVATAR_ACCENT, upperW);
    line(arm[1], arm[2], SKIN, foreW);
  }

  // Head, hair and face, drawn in a frame rotated so +y follows `down` — the
  // face stays upright when the recorded shoulders are tilted.
  ctx.save();
  ctx.translate(headC.x, headC.y);
  ctx.rotate(Math.atan2(down.y, down.x) - Math.PI / 2);
  ctx.beginPath();
  ctx.arc(0, 0, headR, 0, Math.PI * 2);
  ctx.fillStyle = SKIN;
  ctx.fill();
  ctx.save();
  ctx.clip();
  ctx.fillStyle = HAIR;
  ctx.fillRect(-headR, -headR, headR * 2, headR * 0.7);
  ctx.restore();
  ctx.strokeStyle = OUTLINE;
  ctx.lineWidth = outlineW;
  ctx.beginPath();
  ctx.arc(0, 0, headR, 0, Math.PI * 2);
  ctx.stroke();
  // The recording has one face point (the nose), so the expression is fixed
  // rather than data-driven.
  for (const dir of [-1, 1]) {
    ctx.beginPath();
    ctx.arc(dir * headR * 0.36, headR * 0.02, headR * 0.14, 0, Math.PI * 2);
    ctx.fillStyle = OUTLINE;
    ctx.fill();
    ctx.beginPath();
    ctx.arc(dir * headR * 0.36 + headR * 0.05, headR * 0.02 - headR * 0.05, headR * 0.05, 0, Math.PI * 2);
    ctx.fillStyle = '#ffffff';
    ctx.fill();
    ctx.beginPath();
    ctx.arc(dir * headR * 0.58, headR * 0.32, headR * 0.13, 0, Math.PI * 2);
    ctx.fillStyle = BLUSH;
    ctx.fill();
  }
  ctx.beginPath();
  ctx.ellipse(0, headR * 0.28, headR * 0.31, headR * 0.23, 0, 0.15 * Math.PI, 0.85 * Math.PI);
  ctx.strokeStyle = OUTLINE;
  ctx.lineWidth = outlineW * 0.85;
  ctx.stroke();
  ctx.restore();

  // Hands last: signing happens in front of the body.
  const hands = handsForFrame(frames, index);
  const fingerW = shoulderW * 0.105;
  // A hand is a lot of parallel strokes in a small area, so it gets a thinner
  // outline than the body — at the body's weight, curled fingers fill in solid
  // black.
  const handOutlineW = outlineW * 0.5;
  [lWr, rWr].forEach((wrist, slot) => {
    const hand = hands[slot];
    if (hand === null || hand.length < HAND_POINTS) {
      // No hand data anywhere in the clip for this wrist: a plain mitten keeps
      // the arm from ending in a stump.
      ctx.beginPath();
      ctx.arc(wrist.x, wrist.y, shoulderW * 0.19, 0, Math.PI * 2);
      ctx.fillStyle = SKIN;
      ctx.fill();
      ctx.strokeStyle = OUTLINE;
      ctx.lineWidth = outlineW;
      ctx.stroke();
      return;
    }
    const p = hand.map(P);
    const palm = () => {
      ctx.beginPath();
      ctx.moveTo(p[PALM_OUTLINE[0]].x, p[PALM_OUTLINE[0]].y);
      for (const i of PALM_OUTLINE.slice(1)) ctx.lineTo(p[i].x, p[i].y);
      ctx.closePath();
    };
    // Palm first, so the finger outlines land on top of it.
    palm();
    ctx.strokeStyle = OUTLINE;
    ctx.lineWidth = fingerW + handOutlineW * 2;
    ctx.stroke();
    ctx.fillStyle = SKIN;
    ctx.fill();
    palm();
    ctx.lineWidth = handOutlineW;
    ctx.stroke();
    // One finger at a time — outline then fill. Drawing every outline first
    // lets the next finger's fill erase the line between them, which is what
    // turned a spread hand into a mitten. Farthest finger first (landmark z is
    // depth relative to the wrist, negative = toward the camera) so overlaps
    // stack the way the real hand did.
    const meanZ = (finger: number[]) =>
      finger.reduce((sum, i) => sum + hand[i].z, 0) / finger.length;
    for (const finger of [...FINGER_CHAINS].sort((a, b) => meanZ(b) - meanZ(a))) {
      const pts = finger.map((i) => p[i]);
      chain(pts, OUTLINE, fingerW + handOutlineW * 2);
      chain(pts, SKIN, fingerW);
    }
  });
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
      renderAvatarFrame(ctx, frames, idx, size);
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
