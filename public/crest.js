// Default player tokens: small heraldic crests. Derived only from PUBLIC values (room code + seat
// number), never from account identifiers. Stable for the life of a room. Every seat in a room has
// a different charge (shape), so crests are distinguishable without relying on colour.
// A crest implies nothing about a player's abilities.

const FIELDS = [['azure', '#2f4a7a'], ['gules', '#9b2c2c'], ['vert', '#2f6b4a'], ['purpure', '#6b3a7a'],
  ['sable', '#30303a'], ['tenné', '#a35a1f'], ['teal', '#1f6b73'], ['murrey', '#7a2f55']];
const METALS = ['#e6bf55', '#f3eee2'];
const DIVISIONS = [
  ['plain', ''], ['per pale', 'M20 0h20v46H20z'], ['per fess', 'M0 23h40v23H0z'], ['per bend', 'M0 0l40 46H0z'],
  ['a chief', 'M0 0h40v13H0z'], ['a pale', 'M14 0h12v46H14z'], ['a fess', 'M0 16h40v12H0z'], ['quarterly', 'M20 0h20v23H20zM0 23h20v23H0z']];
const CHARGES = [
  ['star', 'M20 12l2.600 5.600 6.100.700-4.500 4.200 1.200 6-5.400-3-5.400 3 1.200-6-4.500-4.200 6.100-.700z'],
  ['crescent', 'M24 13a9 9 0 1 0 0 16 7 7 0 1 1 0-16z'],
  ['cross', 'M17.500 12h5v6.500H29v5h-6.500V30h-5v-6.500H11v-5h6.500z'],
  ['lozenge', 'M20 11l8 10-8 10-8-10z'],
  ['ring', 'M20 12a9 9 0 1 0 0 18 9 9 0 0 0 0-18zm0 5a4 4 0 1 1 0 8 4 4 0 0 1 0-8z'],
  ['tower', 'M13 30V16h-1v-5h3v2h3v-2h4v2h3v-2h3v5h-1v14z'],
  ['arrow', 'M20 10l8 9h-5v11h-6V19h-5z'],
  ['three roundels', 'M20 11a3.500 3.500 0 1 0 0 7 3.500 3.500 0 0 0 0-7zM14 22a3.500 3.500 0 1 0 0 7 3.500 3.500 0 0 0 0-7zM26 22a3.500 3.500 0 1 0 0 7 3.500 3.500 0 0 0 0-7z'],
  ['sun', 'M20 15a6 6 0 1 0 0 12 6 6 0 0 0 0-12zM19 9h2v4h-2zM19 29h2v4h-2zM8 20h4v2H8zM28 20h4v2h-4z'],
  ['leaf', 'M20 10c7 4 9 11 0 21-9-10-7-17 0-21z'],
  ['waves', 'M10 16q5-5 10 0t10 0v4q-5 5-10 0t-10 0zM10 24q5-5 10 0t10 0v4q-5 5-10 0t-10 0z'],
  ['flame', 'M20 10c1 5 7 7 7 13a7 7 0 0 1-14 0c0-3 2-4 3-7 1 2 2 3 3 3 1-3 0-6 1-9z'],
  ['chevron', 'M20 12l10 10v6L20 18 10 28v-6z'],
  ['crown', 'M11 28l-1-12 5 5 5-9 5 9 5-5-1 12z'],
  ['bars', 'M11 12h18v4H11zM11 19h18v4H11zM11 26h18v4H11z'],
  ['bell', 'M20 10a2 2 0 0 1 2 2c4 1.500 5 5 5 9l2 5H11l2-5c0-4 1-7.500 5-9a2 2 0 0 1 2-2zM17.500 28h5a2.500 2.500 0 0 1-5 0z'],
  ['tree', 'M20 9l8 10h-4l5 7h-7v5h-4v-5h-7l5-7h-4z'],
  ['fish', 'M9 21c4-6 11-7 16-3l5-4v14l-5-4c-5 4-12 3-16-3z'],
  ['hourglass', 'M12 10h16v3l-6 8 6 8v3H12v-3l6-8-6-8z'],
  ['mountain', 'M8 30l8-14 4 6 3-4 9 12z']];
const SHIELD = 'M2 2h36v22c0 10-7 17-18 21C9 41 2 34 2 24z';

function hash(text) { // FNV-1a, 32-bit
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h;
}

/** Pure description of a seat's crest. */
export function crestSpec(roomCode, seat) {
  const base = hash('crest:' + String(roomCode));
  const charge = CHARGES[(base + seat) % CHARGES.length];
  const field = FIELDS[((base >>> 5) + seat * 3) % FIELDS.length];
  const second = FIELDS[((base >>> 5) + seat * 3 + 1 + ((base >>> 9) + seat) % (FIELDS.length - 1)) % FIELDS.length];
  const division = DIVISIONS[((base >>> 13) + seat * 5) % DIVISIONS.length];
  return { field: field[1], fieldName: field[0], division: { name: division[0], path: division[1], color: second[1] },
    charge: { name: charge[0], path: charge[1] }, metal: METALS[((base >>> 17) + seat) % METALS.length] };
}

let serial = 0;
/** SVG element for a seat. `label` becomes its accessible name; omit it for decorative use. */
export function crestElement(roomCode, seat, label) {
  const spec = crestSpec(roomCode, seat), ns = 'http://www.w3.org/2000/svg', id = 'crest-clip-' + (++serial);
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', '0 0 40 47'); svg.setAttribute('class', 'crest');
  if (label) { svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', label); } else svg.setAttribute('aria-hidden', 'true');
  const add = (parent, tag, attrs) => { const n = document.createElementNS(ns, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); parent.append(n); return n; };
  add(add(svg, 'clipPath', { id }), 'path', { d: SHIELD });
  const body = add(svg, 'g', { 'clip-path': `url(#${id})` });
  add(body, 'path', { d: 'M0 0h40v47H0z', fill: spec.field });
  if (spec.division.path) add(body, 'path', { d: spec.division.path, fill: spec.division.color });
  add(svg, 'path', { d: spec.charge.path, fill: spec.metal, stroke: 'rgba(0,0,0,.55)', 'stroke-width': '.8', 'fill-rule': 'evenodd', 'stroke-linejoin': 'round' });
  add(svg, 'path', { d: SHIELD, fill: 'none', class: 'crest-edge', 'stroke-width': '2' });
  return svg;
}
/** Short public name players can use for a token, e.g. "the tower". */
export const crestName = (roomCode, seat) => 'the ' + crestSpec(roomCode, seat).charge.name;

// ---- Chess-style coordinates. a1 is the lower-left square; server rows count from the top. ----
const FILES = 'abcdefghijklmnopqrstuvwxyz';
export const fileLabel = (x) => FILES[x] || '?';
export const rankLabel = (y, size) => String(size - y);
export const square = (x, y, size) => fileLabel(x) + rankLabel(y, size);
export function parseSquare(text, size) {
  const match = /^([a-z])(\d{1,2})$/.exec(String(text).trim().toLowerCase());
  if (!match) return null;
  const x = FILES.indexOf(match[1]), y = size - Number(match[2]);
  return x >= 0 && x < size && y >= 0 && y < size ? { x, y } : null;
}
