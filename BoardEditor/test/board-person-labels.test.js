import { test, expect } from 'bun:test';
import { validatedAuthorNames, boardAuthorName } from '../web/sol/board-editor/person-labels.js';

test('board author names are bounded display data with exact keys and safe fallback', () => {
  const identity = `npub1${'q'.repeat(58)}`; // Host independently validates checksum.
  let names = validatedAuthorNames({ [identity]: '<img src=x> Ada', npub1bad: 'Wrong' });
  expect(boardAuthorName(identity, names)).toBe('<img src=x> Ada');
  expect(boardAuthorName('npub1bad', names)).toBe('Unknown person');
  names = validatedAuthorNames({ [identity]: 'Renamed' });
  expect(boardAuthorName(identity, names)).toBe('Renamed');
  expect(validatedAuthorNames({ [identity]: identity })).toEqual({});
  expect(validatedAuthorNames({ [identity]: 'x'.repeat(257) })).toEqual({});
  expect(validatedAuthorNames(null)).toEqual({});
});
