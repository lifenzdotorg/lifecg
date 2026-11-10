import { expect, it } from 'vitest';
import { formatServiceDate, zonedToIso } from '../shared/time';

it('converts NZ local time with daylight saving', () => {
  expect(zonedToIso('2026-11-15', '09:30')).toEqual({ iso: '2026-11-15T09:30:00+13:00', utc: '2026-11-14T20:30:00.000Z' });
  expect(zonedToIso('2026-06-14', '18:00')).toEqual({ iso: '2026-06-14T18:00:00+12:00', utc: '2026-06-14T06:00:00.000Z' });
});
it('formats service dates', () => {
  expect(formatServiceDate('2026-11-15T09:30:00+13:00')).toBe('Sun 15 Nov 9:30am');
});
