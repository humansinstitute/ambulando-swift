import { boardComments, followCommentAnchors, mergeBoardComments, normalizeBoardComments } from './board-comments.js';

// Canonical Excalidraw board scenes. A board is a Flight Deck File whose
// immutable versions hold this JSON. The canonical working scene keeps every
// element (including `isDeleted` tombstones), element `version`/`versionNonce`
// and embedded image files so later reconciliation or live collaboration can
// merge by element identity. Public exports are a separate, lossy projection.

export const BOARD_CONTENT_TYPE = 'application/vnd.excalidraw+json';
export const BOARD_FILE_EXTENSION = '.excalidraw';
export const BOARD_SOURCE = 'wingman-ambulando';
export const BOARD_LIMITS = Object.freeze({
  bytes: 24 * 1024 * 1024,
  elements: 20000,
  files: 200,
  fileBytes: 6 * 1024 * 1024,
  summary: 280,
  title: 200,
});
export const BOARD_IMAGE_TYPES = Object.freeze(['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/svg+xml']);
// Board-level appState that belongs to the drawing rather than to one viewer.
// Values equal to Excalidraw's defaults are omitted, so an untouched board never
// differs from its saved version.
export const BOARD_APP_STATE_DEFAULTS = Object.freeze({ viewBackgroundColor: '#ffffff', gridSize: 20, gridStep: 5, gridModeEnabled: false });
export const BOARD_PERSISTED_APP_STATE = Object.freeze(Object.keys(BOARD_APP_STATE_DEFAULTS));

const isObject = value => Boolean(value) && typeof value === 'object' && !Array.isArray(value);
const text = value => String(value ?? '').trim();

export class BoardSceneError extends Error {
  constructor(message, code = 'invalid_board_scene') {
    super(message);
    this.name = 'BoardSceneError';
    this.code = code;
  }
}

export function createEmptyBoardScene() {
  return { type: 'excalidraw', version: 2, source: BOARD_SOURCE, elements: [], appState: {}, files: {} };
}

function pickAppState(value) {
  const appState = {};
  if (!isObject(value)) return appState;
  for (const key of BOARD_PERSISTED_APP_STATE) {
    if (value[key] !== undefined && value[key] !== null && value[key] !== BOARD_APP_STATE_DEFAULTS[key]) appState[key] = value[key];
  }
  return appState;
}

function validateElement(element, seen) {
  if (!isObject(element)) throw new BoardSceneError('Board element must be an object');
  const id = text(element.id);
  if (!id || id.length > 128) throw new BoardSceneError('Board element id is missing or too long');
  if (seen.has(id)) throw new BoardSceneError(`Duplicate board element id ${id}`);
  seen.add(id);
  if (!text(element.type)) throw new BoardSceneError(`Board element ${id} has no type`);
  if (!Number.isSafeInteger(element.version) || element.version < 1) throw new BoardSceneError(`Board element ${id} has an invalid version`);
  if (element.versionNonce !== undefined && !Number.isSafeInteger(element.versionNonce)) throw new BoardSceneError(`Board element ${id} has an invalid versionNonce`);
  if (element.isDeleted !== undefined && typeof element.isDeleted !== 'boolean') throw new BoardSceneError(`Board element ${id} has an invalid isDeleted flag`);
  // Keep every field verbatim: unknown Excalidraw fields must survive a save.
  return element;
}

function validateFile(id, file) {
  if (!isObject(file)) throw new BoardSceneError(`Board file ${id} must be an object`);
  if (text(file.id) && text(file.id) !== id) throw new BoardSceneError(`Board file ${id} has a mismatched id`);
  const mimeType = text(file.mimeType).toLowerCase();
  if (!BOARD_IMAGE_TYPES.includes(mimeType)) throw new BoardSceneError(`Board file ${id} has an unsupported type`);
  const dataURL = String(file.dataURL || '');
  const prefix = `data:${mimeType}`;
  if (!dataURL.toLowerCase().startsWith(prefix)) throw new BoardSceneError(`Board file ${id} must be an embedded ${mimeType} data URL`);
  if (dataURL.length > Math.ceil(BOARD_LIMITS.fileBytes * 4 / 3) + 128) throw new BoardSceneError(`Board file ${id} is too large`);
  return { ...file, id, mimeType, dataURL };
}

/**
 * Accepts a standard `.excalidraw` document, a bare `{elements, files}` scene,
 * or the Artifact-style `{scene: {...}}` wrapper. Returns the canonical shape.
 */
export function normalizeBoardScene(input) {
  let value = input;
  if (isObject(value) && isObject(value.scene) && Array.isArray(value.scene.elements)) value = { ...value.scene, wingman: value.wingman || value.scene.wingman };
  if (!isObject(value) || !Array.isArray(value.elements)) throw new BoardSceneError('Board scene must contain an elements array');
  if (value.type !== undefined && value.type !== 'excalidraw') throw new BoardSceneError('Board scene type must be "excalidraw"');
  if (value.elements.length > BOARD_LIMITS.elements) throw new BoardSceneError('Board has too many elements', 'board_too_large');
  const seen = new Set();
  const elements = value.elements.map(element => validateElement(element, seen));
  const fileEntries = Object.entries(isObject(value.files) ? value.files : {});
  if (fileEntries.length > BOARD_LIMITS.files) throw new BoardSceneError('Board has too many images', 'board_too_large');
  const files = Object.fromEntries(fileEntries.map(([id, file]) => [id, validateFile(id, file)]));
  const scene = { type: 'excalidraw', version: 2, source: text(value.source) || BOARD_SOURCE, elements, appState: pickAppState(value.appState), files };
  if (isObject(value.wingman)) {
    scene.wingman = pickWingmanMetadata(value.wingman);
    if (scene.wingman.comments) scene.wingman.comments = followCommentAnchors(scene.wingman.comments, elements);
  }
  return scene;
}

function pickWingmanMetadata(value) {
  const metadata = {};
  const summary = text(value.summary).slice(0, BOARD_LIMITS.summary);
  if (summary) metadata.summary = summary;
  if (text(value.base_version_id)) metadata.base_version_id = text(value.base_version_id);
  if (value.comments !== undefined) metadata.comments = normalizeBoardComments(value.comments);
  return metadata;
}

export function parseBoardScene(source) {
  let raw = source;
  if (raw instanceof ArrayBuffer || ArrayBuffer.isView(raw)) {
    const bytes = raw instanceof ArrayBuffer ? new Uint8Array(raw) : new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength);
    if (bytes.byteLength > BOARD_LIMITS.bytes) throw new BoardSceneError('Board is larger than the 24 MiB limit', 'board_too_large');
    raw = new TextDecoder().decode(bytes);
  }
  if (typeof raw === 'string') {
    try { raw = JSON.parse(raw); } catch { throw new BoardSceneError('Board is not valid JSON'); }
  }
  return normalizeBoardScene(raw);
}

/** Images referenced by any element, including deleted ones (needed to undelete or reconcile). */
export function referencedFileIds(elements) {
  return new Set((elements || []).map(element => text(element?.fileId)).filter(Boolean));
}

/**
 * Canonical bytes for one immutable board version. Unreferenced images are
 * pruned; deleted elements and their images are retained.
 */
export function serializeBoardScene(scene, { summary = '', baseVersionId = '' } = {}) {
  const normalized = normalizeBoardScene(scene);
  const referenced = referencedFileIds(normalized.elements);
  const files = Object.fromEntries(Object.entries(normalized.files).filter(([id]) => referenced.has(id)).sort(([a], [b]) => a.localeCompare(b)));
  const wingman = pickWingmanMetadata({ ...normalized.wingman, summary, base_version_id: baseVersionId, ...(normalized.wingman?.comments ? { comments: followCommentAnchors(boardComments(normalized), normalized.elements) } : {}) });
  const document = { type: 'excalidraw', version: 2, source: BOARD_SOURCE, elements: normalized.elements, appState: normalized.appState, files };
  if (Object.keys(wingman).length) document.wingman = wingman;
  const json = JSON.stringify(document);
  const bytes = new TextEncoder().encode(json);
  if (bytes.byteLength > BOARD_LIMITS.bytes) throw new BoardSceneError('Board is larger than the 24 MiB limit. Remove or shrink some images.', 'board_too_large');
  return { json, bytes, scene: document };
}

/**
 * Change identity used for dirty detection. Excalidraw bumps `version` and
 * `versionNonce` on every element mutation, so selection, zoom and scroll do
 * not make a board dirty.
 */
export function boardSceneFingerprint(scene) {
  const elements = (scene?.elements || []).map(element => `${element.id}:${element.version}:${element.versionNonce ?? 0}:${element.isDeleted ? 1 : 0}`).sort();
  const files = Object.keys(scene?.files || {}).filter(id => referencedFileIds(scene?.elements).has(id)).sort();
  return JSON.stringify([elements, files, pickAppState(scene?.appState), boardComments(scene)]);
}

function elementStamp(element) {
  return element ? `${element.version}:${element.versionNonce ?? 0}` : '';
}

/**
 * Three-way rebase of a local draft onto a newer saved version, by element id.
 * Elements the draft changed since `base` win; otherwise the newer saved
 * version wins. Elements changed on both sides are reported as conflicts and
 * resolved toward the draft so no local edit is dropped. Deletions are
 * tombstones (`isDeleted`), so they merge like any other change.
 */
export function rebaseBoardScene({ base, draft, latest }) {
  const baseById = new Map((base?.elements || []).map(element => [element.id, element]));
  const draftById = new Map((draft?.elements || []).map(element => [element.id, element]));
  const latestById = new Map((latest?.elements || []).map(element => [element.id, element]));
  const conflicts = [];
  const order = [...(latest?.elements || []).map(element => element.id)];
  for (const element of draft?.elements || []) if (!latestById.has(element.id)) order.push(element.id);
  const elements = order.map(id => {
    const before = baseById.get(id), mine = draftById.get(id), theirs = latestById.get(id);
    const mineChanged = Boolean(mine) && elementStamp(mine) !== elementStamp(before);
    const theirsChanged = Boolean(theirs) && elementStamp(theirs) !== elementStamp(before);
    if (mineChanged && theirsChanged && elementStamp(mine) !== elementStamp(theirs)) conflicts.push(id);
    if (mineChanged) return mine;
    return theirs || mine;
  });
  const draftAppStateChanged = JSON.stringify(pickAppState(draft?.appState)) !== JSON.stringify(pickAppState(base?.appState));
  const files = { ...(latest?.files || {}), ...(draft?.files || {}) };
  const appState = draftAppStateChanged ? pickAppState(draft?.appState) : pickAppState(latest?.appState);
  const discussion = mergeBoardComments(base, draft, latest);
  conflicts.push(...discussion.conflicts);
  return { scene: { wingman: { comments: followCommentAnchors(discussion.comments, elements) }, type: 'excalidraw', version: 2, source: BOARD_SOURCE, elements, appState, files }, conflicts };
}

/** Lossy public/export projection: live elements and their images only. */
export function exportPublicBoardScene(scene) {
  const elements = (scene?.elements || []).filter(element => !element.isDeleted);
  const referenced = referencedFileIds(elements);
  const files = Object.fromEntries(Object.entries(scene?.files || {}).filter(([id]) => referenced.has(id)));
  return { type: 'excalidraw', version: 2, source: BOARD_SOURCE, elements, appState: pickAppState(scene?.appState), files };
}

export function boardFileName(title) {
  const printable = [...text(title)].map(character => character.charCodeAt(0) < 32 ? ' ' : character).join('');
  const base = printable.replace(/[\\/:*?"<>|]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 120) || 'Board';
  return base.toLowerCase().endsWith(BOARD_FILE_EXTENSION) ? base : `${base}${BOARD_FILE_EXTENSION}`;
}

export function isBoardFileRow(row) {
  const type = text(row?.content_storage_content_type || row?.content_type || row?.mime_type).toLowerCase();
  return row?.pg_record_type === 'file' && (type === BOARD_CONTENT_TYPE || text(row?.title || row?.file_name).toLowerCase().endsWith(BOARD_FILE_EXTENSION));
}

function nextNonce() {
  const values = new Uint32Array(1);
  globalThis.crypto.getRandomValues(values);
  return values[0] & 0x7fffffff;
}

/**
 * Turns an older saved version into a draft on top of `latest`. Each element is
 * re-stamped above the newest known version so that a later rebase or live
 * collaboration layer sees the restore as the most recent change. Elements
 * that exist only in `latest` become tombstones rather than disappearing.
 */
export function restoreBoardScene({ target, latest }) {
  const latestById = new Map((latest?.elements || []).map(element => [element.id, element]));
  const targetIds = new Set((target?.elements || []).map(element => element.id));
  const restamp = (element, previous) => ({ ...element, version: Math.max(element.version, previous?.version || 0) + 1, versionNonce: nextNonce(), updated: Date.now() });
  const elements = [
    ...(target?.elements || []).map(element => restamp(element, latestById.get(element.id))),
    ...(latest?.elements || []).filter(element => !targetIds.has(element.id)).map(element => element.isDeleted ? element : { ...restamp(element, element), isDeleted: true }),
  ];
  // Restoring a drawing never erases discussion that arrived in later versions.
  const discussion = mergeBoardComments({}, latest, target);
  return { wingman: { comments: followCommentAnchors(discussion.comments, elements) }, type: 'excalidraw', version: 2, source: BOARD_SOURCE, elements, appState: pickAppState(target?.appState), files: { ...(latest?.files || {}), ...(target?.files || {}) } };
}
