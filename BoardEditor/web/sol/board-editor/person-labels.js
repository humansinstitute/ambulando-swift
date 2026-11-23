// Names are untrusted display data, rendered as React text, never scene data.
export function validatedAuthorNames(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value).slice(0, 2000).filter(([identity, name]) =>
    /^npub1[0-9a-z]{58}$/.test(identity) && typeof name === 'string' && name.trim() && name.length <= 256
    && !/(?:npub1[0-9a-z]+|\b[0-9a-f]{64}\b)/i.test(name)).map(([identity, name]) => [identity, name.trim()]));
}
export function boardAuthorName(identity, names) {
  return Object.hasOwn(names || {}, identity) ? names[identity] : 'Unknown person';
}
