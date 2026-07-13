'use client';

import { useEffect, useState, FormEvent } from 'react';
import {
  fetchLearnTopics,
  fetchLearnSigns,
  createLearnTopic,
  updateLearnTopic,
  deleteLearnTopic,
  createLearnExercise,
  updateLearnExercise,
  deleteLearnExercise,
  LearnTopic,
  LearnExercise,
  LearnSign,
  pct,
} from '../../lib/api';

type TopicForm = {
  slug: string;
  title: string;
  icon: string;
  sort_order: number;
  published: boolean;
};

const emptyTopicForm: TopicForm = { slug: '', title: '', icon: '', sort_order: 0, published: true };

export default function LearnPage() {
  const [topics, setTopics] = useState<LearnTopic[]>([]);
  const [signs, setSigns] = useState<LearnSign[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  // Topic create/edit form: editingTopic === 0 means "create new".
  const [editingTopic, setEditingTopic] = useState<number | null>(null);
  const [topicForm, setTopicForm] = useState<TopicForm>(emptyTopicForm);
  const [savingTopic, setSavingTopic] = useState(false);
  const [confirmDeleteTopic, setConfirmDeleteTopic] = useState<number | null>(null);

  // Per-topic "add exercise" form.
  const [addingTo, setAddingTo] = useState<number | null>(null);
  const [newWord, setNewWord] = useState('');
  const [newThreshold, setNewThreshold] = useState(80);
  const [savingExercise, setSavingExercise] = useState(false);
  const [confirmDeleteEx, setConfirmDeleteEx] = useState<number | null>(null);

  // Inline exercise threshold/published edits keyed by exercise id.
  const [editingEx, setEditingEx] = useState<number | null>(null);
  const [exThreshold, setExThreshold] = useState(80);

  async function load() {
    try {
      const [t, s] = await Promise.all([fetchLearnTopics(), fetchLearnSigns()]);
      setTopics(t);
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

  function startEditTopic(t: LearnTopic) {
    setEditingTopic(t.id);
    setTopicForm({
      slug: t.slug,
      title: t.title,
      icon: t.icon,
      sort_order: t.sort_order,
      published: t.published,
    });
  }

  async function handleSaveTopic(e: FormEvent) {
    e.preventDefault();
    setSavingTopic(true);
    setNotice(null);
    try {
      if (editingTopic === 0) {
        await createLearnTopic(topicForm);
        setNotice({ type: 'success', text: `Topic "${topicForm.title}" created.` });
      } else if (editingTopic !== null) {
        await updateLearnTopic(editingTopic, topicForm);
        setNotice({ type: 'success', text: `Topic "${topicForm.title}" updated.` });
      }
      setEditingTopic(null);
      setTopicForm(emptyTopicForm);
      await load();
    } catch (err) {
      fail('Failed to save topic', err);
    } finally {
      setSavingTopic(false);
    }
  }

  async function handleDeleteTopic(id: number) {
    setConfirmDeleteTopic(null);
    try {
      await deleteLearnTopic(id);
      setNotice({ type: 'success', text: 'Topic deleted (with its exercises).' });
      await load();
    } catch (err) {
      fail('Failed to delete topic', err);
    }
  }

  async function handleAddExercise(e: FormEvent, topic: LearnTopic) {
    e.preventDefault();
    setSavingExercise(true);
    setNotice(null);
    try {
      await createLearnExercise({
        topic_id: topic.id,
        word: newWord,
        sort_order: topic.exercises.length,
        pass_confidence: newThreshold / 100,
        published: true,
      });
      setNotice({ type: 'success', text: `Exercise "${newWord}" added to ${topic.title}.` });
      setAddingTo(null);
      setNewWord('');
      setNewThreshold(80);
      await load();
    } catch (err) {
      fail('Failed to add exercise', err);
    } finally {
      setSavingExercise(false);
    }
  }

  async function handleSaveExercise(ex: LearnExercise) {
    setNotice(null);
    try {
      await updateLearnExercise(ex.id, {
        topic_id: ex.topic_id,
        word: ex.word,
        sort_order: ex.sort_order,
        pass_confidence: exThreshold / 100,
        published: ex.published,
      });
      setNotice({ type: 'success', text: `"${ex.word}" pass threshold set to ${exThreshold}%.` });
      setEditingEx(null);
      await load();
    } catch (err) {
      fail('Failed to update exercise', err);
    }
  }

  async function handleToggleExercise(ex: LearnExercise) {
    setNotice(null);
    try {
      await updateLearnExercise(ex.id, {
        topic_id: ex.topic_id,
        word: ex.word,
        sort_order: ex.sort_order,
        pass_confidence: ex.pass_confidence,
        published: !ex.published,
      });
      await load();
    } catch (err) {
      fail('Failed to update exercise', err);
    }
  }

  async function handleDeleteExercise(id: number) {
    setConfirmDeleteEx(null);
    try {
      await deleteLearnExercise(id);
      setNotice({ type: 'success', text: 'Exercise deleted.' });
      await load();
    } catch (err) {
      fail('Failed to delete exercise', err);
    }
  }

  const exerciseCount = topics.reduce((n, t) => n + t.exercises.length, 0);

  return (
    <div>
      <h1>Learning</h1>
      <p className="subtitle">
        Manage the Learn tab roadmap: topics, perform-the-sign exercises, and their pass-confidence thresholds
      </p>

      {notice && <div className={`notice ${notice.type}`}>{notice.text}</div>}
      {error && <div className="notice error">Failed to load learning content: {error}</div>}

      <div className="row" style={{ marginBottom: 16 }}>
        <button
          id="create-topic-btn"
          onClick={() => {
            setEditingTopic(editingTopic === 0 ? null : 0);
            setTopicForm({ ...emptyTopicForm, sort_order: topics.length });
          }}
        >
          {editingTopic === 0 ? 'Cancel' : '+ Create Topic'}
        </button>
        <span className="chip info">
          <span className="dot" />
          {topics.length} topic{topics.length !== 1 ? 's' : ''} · {exerciseCount} exercise
          {exerciseCount !== 1 ? 's' : ''}
        </span>
      </div>

      {editingTopic !== null && (
        <div className="card" style={{ marginBottom: 20 }}>
          <h2>{editingTopic === 0 ? 'New Topic' : 'Edit Topic'}</h2>
          <form onSubmit={handleSaveTopic}>
            <label className="field">
              <span>Slug (unique, latin)</span>
              <input
                value={topicForm.slug}
                onChange={(e) => setTopicForm({ ...topicForm, slug: e.target.value })}
                placeholder="food"
                required
              />
            </label>
            <label className="field">
              <span>Title (shown in the app)</span>
              <input
                value={topicForm.title}
                onChange={(e) => setTopicForm({ ...topicForm, title: e.target.value })}
                placeholder="อาหารและเครื่องดื่ม"
                required
              />
            </label>
            <label className="field">
              <span>Icon (emoji)</span>
              <input
                value={topicForm.icon}
                onChange={(e) => setTopicForm({ ...topicForm, icon: e.target.value })}
                placeholder="🍚"
              />
            </label>
            <label className="field">
              <span>Sort order</span>
              <input
                type="number"
                value={topicForm.sort_order}
                onChange={(e) => setTopicForm({ ...topicForm, sort_order: Number(e.target.value) })}
              />
            </label>
            <label className="field">
              <span>Published</span>
              <select
                value={topicForm.published ? 'yes' : 'no'}
                onChange={(e) => setTopicForm({ ...topicForm, published: e.target.value === 'yes' })}
              >
                <option value="yes">Published</option>
                <option value="no">Hidden</option>
              </select>
            </label>
            <button type="submit" disabled={savingTopic}>
              {savingTopic ? 'Saving...' : 'Save Topic'}
            </button>
          </form>
        </div>
      )}

      {loading ? (
        <div className="empty">Loading learning content...</div>
      ) : topics.length === 0 ? (
        <div className="empty">No topics yet — create the first one.</div>
      ) : (
        topics.map((topic) => (
          <div className="card" style={{ marginBottom: 16 }} key={topic.id}>
            <div className="row" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
              <h2 style={{ margin: 0 }}>
                {topic.icon} {topic.title}{' '}
                <span className={`chip ${topic.published ? 'info' : 'warning'}`} style={{ fontSize: 10 }}>
                  <span className="dot" />
                  {topic.published ? 'published' : 'hidden'}
                </span>
              </h2>
              <span className="row" style={{ gap: 6 }}>
                <button
                  className="secondary"
                  style={{ fontSize: 12, padding: '4px 10px' }}
                  onClick={() => startEditTopic(topic)}
                >
                  Edit
                </button>
                {confirmDeleteTopic === topic.id ? (
                  <>
                    <button
                      className="secondary"
                      style={{ fontSize: 12, padding: '4px 10px' }}
                      onClick={() => handleDeleteTopic(topic.id)}
                    >
                      Confirm delete
                    </button>
                    <button
                      className="secondary"
                      style={{ fontSize: 12, padding: '4px 10px' }}
                      onClick={() => setConfirmDeleteTopic(null)}
                    >
                      Cancel
                    </button>
                  </>
                ) : (
                  <button
                    className="secondary"
                    style={{ fontSize: 12, padding: '4px 10px' }}
                    onClick={() => setConfirmDeleteTopic(topic.id)}
                  >
                    Delete
                  </button>
                )}
              </span>
            </div>
            <p className="subtitle" style={{ marginTop: 0 }}>
              slug: {topic.slug} · order {topic.sort_order}
            </p>

            {topic.exercises.length === 0 ? (
              <div className="empty">No exercises in this topic.</div>
            ) : (
              <div className="tablewrap">
                <table>
                  <thead>
                    <tr>
                      <th>#</th>
                      <th>Word</th>
                      <th>Pass threshold</th>
                      <th>Status</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    {topic.exercises.map((ex) => (
                      <tr key={ex.id}>
                        <td>{ex.sort_order + 1}</td>
                        <td className="word">{ex.word}</td>
                        <td>
                          {editingEx === ex.id ? (
                            <span className="row" style={{ gap: 6 }}>
                              <input
                                type="number"
                                min={0}
                                max={100}
                                value={exThreshold}
                                onChange={(e) => setExThreshold(Number(e.target.value))}
                                style={{ width: 70 }}
                              />
                              %
                              <button
                                className="secondary"
                                style={{ fontSize: 12, padding: '4px 10px' }}
                                onClick={() => handleSaveExercise(ex)}
                              >
                                Save
                              </button>
                              <button
                                className="secondary"
                                style={{ fontSize: 12, padding: '4px 10px' }}
                                onClick={() => setEditingEx(null)}
                              >
                                Cancel
                              </button>
                            </span>
                          ) : (
                            <span>{pct(ex.pass_confidence)}</span>
                          )}
                        </td>
                        <td>
                          <span className={`chip ${ex.published ? 'info' : 'warning'}`}>
                            <span className="dot" />
                            {ex.published ? 'published' : 'hidden'}
                          </span>
                        </td>
                        <td>
                          <span className="row" style={{ gap: 6 }}>
                            {editingEx !== ex.id && (
                              <button
                                className="secondary"
                                style={{ fontSize: 12, padding: '4px 10px' }}
                                onClick={() => {
                                  setEditingEx(ex.id);
                                  setExThreshold(Math.round(ex.pass_confidence * 100));
                                }}
                              >
                                Edit threshold
                              </button>
                            )}
                            <button
                              className="secondary"
                              style={{ fontSize: 12, padding: '4px 10px' }}
                              onClick={() => handleToggleExercise(ex)}
                            >
                              {ex.published ? 'Hide' : 'Publish'}
                            </button>
                            {confirmDeleteEx === ex.id ? (
                              <>
                                <button
                                  className="secondary"
                                  style={{ fontSize: 12, padding: '4px 10px' }}
                                  onClick={() => handleDeleteExercise(ex.id)}
                                >
                                  Confirm
                                </button>
                                <button
                                  className="secondary"
                                  style={{ fontSize: 12, padding: '4px 10px' }}
                                  onClick={() => setConfirmDeleteEx(null)}
                                >
                                  Cancel
                                </button>
                              </>
                            ) : (
                              <button
                                className="secondary"
                                style={{ fontSize: 12, padding: '4px 10px' }}
                                onClick={() => setConfirmDeleteEx(ex.id)}
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

            {addingTo === topic.id ? (
              <form className="row" style={{ marginTop: 12, gap: 8 }} onSubmit={(e) => handleAddExercise(e, topic)}>
                <select value={newWord} onChange={(e) => setNewWord(e.target.value)} required>
                  <option value="" disabled>
                    Select word…
                  </option>
                  {signs.map((s) => (
                    <option key={s.word} value={s.word}>
                      {s.word} ({s.category})
                    </option>
                  ))}
                </select>
                <input
                  type="number"
                  min={0}
                  max={100}
                  value={newThreshold}
                  onChange={(e) => setNewThreshold(Number(e.target.value))}
                  style={{ width: 70 }}
                />
                <span>% pass threshold</span>
                <button type="submit" disabled={savingExercise || newWord === ''}>
                  {savingExercise ? 'Adding...' : 'Add'}
                </button>
                <button className="secondary" type="button" onClick={() => setAddingTo(null)}>
                  Cancel
                </button>
              </form>
            ) : (
              <button
                className="secondary"
                style={{ marginTop: 12, fontSize: 12, padding: '4px 10px' }}
                onClick={() => {
                  setAddingTo(topic.id);
                  setNewWord('');
                  setNewThreshold(80);
                }}
              >
                + Add Exercise
              </button>
            )}
          </div>
        ))
      )}
    </div>
  );
}
