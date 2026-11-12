// Small shared DOM helpers and the one icon set used across the app.
export const $ = (id) => document.getElementById(id);
export const text = (id, value) => { $(id).textContent = value ?? ''; };
export function node(tag, content, cls) {
  const n = document.createElement(tag);
  if (content !== undefined && content !== null) n.textContent = content;
  if (cls) n.className = cls;
  return n;
}
export const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

// One visual language for each game concept. Stroke icons inherit the text colour.
const ICONS = {
  menu: 'M4 7h16M4 12h16M4 17h16', close: 'M6 6l12 12M18 6L6 18',
  field: 'M3 3h18v18H3zM9 3v18M15 3v18M3 9h18M3 15h18',
  chat: 'M21 11a8 8 0 0 1-8 8H8l-5 3V8a5 5 0 0 1 5-5h8a5 5 0 0 1 5 5z',
  council: 'M12 3v18M5 7h14M5 7l-3 7a3 3 0 0 0 6 0zM19 7l-3 7a3 3 0 0 0 6 0zM8 21h8',
  players: 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21v-1a7 7 0 0 1 14 0v1M17 4a4 4 0 0 1 0 7M19 14a6 6 0 0 1 3 6v1',
  dispatch: 'M5 3h11l3 3v15H5zM9 9h6M9 13h6M9 17h4',
  settings: 'M4 6h16M4 12h16M4 18h16M8 4v4M16 10v4M10 16v4',
  desk: 'M3 8h18v12H3zM8 8V4h8v4M3 13h18',
  point: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 8v8M9 10h4.500a1.500 1.500 0 0 1 0 3H9',
  heart: 'M12 20s-7-4.500-7-10a4 4 0 0 1 7-2.500A4 4 0 0 1 19 10c0 5.500-7 10-7 10z',
  range: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 1v4M12 19v4M1 12h4M19 12h4',
  shield: 'M12 3l8 3v6c0 5-3.500 8-8 9-4.500-1-8-4-8-9V6z',
  move: 'M12 3v18M3 12h18M12 3l-3 3M12 3l3 3M12 21l-3-3M12 21l3-3M3 12l3-3M3 12l3 3M21 12l-3-3M21 12l-3 3',
  attack: 'M19 3l-9 9M19 3h-4M19 3v4M5 15l4 4M4 20l3-3M10 12l2 2',
  give: 'M4 12h13M13 7l5 5-5 5M4 6v12',
  bell: 'M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0',
  reply: 'M9 7L4 12l5 5M4 12h10a6 6 0 0 1 6 6v1', vote: 'M5 11l4 4 9-10M4 20h16',
};
/** Icon element. With a label it is announced; without one it is decorative. */
export function icon(name, label) {
  const ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg'), path = document.createElementNS(ns, 'path');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('class', 'icon icon-' + name);
  path.setAttribute('d', ICONS[name] || ''); svg.append(path);
  if (label) { svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', label); const t = document.createElementNS(ns, 'title'); t.textContent = label; svg.prepend(t); }
  else svg.setAttribute('aria-hidden', 'true');
  return svg;
}
export function hydrateIcons(root = document) {
  root.querySelectorAll('[data-icon]').forEach((slot) => { if (!slot.firstChild) slot.append(icon(slot.dataset.icon)); });
}

// Uploaded images are only ever small PNG data URLs produced by the picker and validated by the server.
export const safeIcon = (s) => typeof s === 'string' && s.length <= 25000 && /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(s);

/** Confirmation dialog. Resolves with {confirmed, input}. Escape or "Not yet" cancels. */
export function confirmDialog({ title, body, cost = '', label = 'Confirm', danger = false, input = null }) {
  return new Promise((resolve) => {
    const dialog = $('decisionDialog');
    if (dialog.open) { resolve({ confirmed: false, input: '' }); return; }
    text('dialogTitle', title); text('dialogBody', body); text('dialogCost', cost); $('dialogCost').hidden = !cost;
    $('dialogInputWrap').hidden = !input; $('dialogInput').value = '';
    if (input) { text('dialogInputLabel', input.label); $('dialogInput').maxLength = input.max || 500; }
    const button = $('dialogConfirm'); button.textContent = label; button.className = danger ? 'danger' : 'primary';
    dialog.addEventListener('close', () => resolve({ confirmed: dialog.returnValue === 'confirm', input: $('dialogInput').value.trim() }), { once: true });
    dialog.returnValue = ''; dialog.showModal();
  });
}

export async function copyText(value) {
  try { await navigator.clipboard.writeText(value); return true; } catch { return false; }
}
