export const FLIGHTDECK_PROSEMIRROR_CONTENT_FORMAT = 'flightdeck_prosemirror_v1';
export const PROSEMIRROR_JSON_FORMAT = 'prosemirror_json_v1';
export const PROSEMIRROR_JSON_VERSION = 1;

export function createFlightDeckBlockId() {
  return globalThis.crypto?.randomUUID
    ? `pm_${globalThis.crypto.randomUUID()}`
    : `pm_${Date.now()}_${Math.random().toString(36).slice(2)}`;
}
