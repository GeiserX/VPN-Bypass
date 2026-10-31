// Line glyphs for the rework mockups: <i data-g="name"></i> becomes a 14 px SVG that takes
// the element's classes (g, live, attn...). Shapes approximate the SF Symbols the app uses.
const P = {
  globe: '<circle cx="8" cy="8" r="6.2"/><path d="M1.8 8h12.4M8 1.8c2 2 2 10.4 0 12.4M8 1.8c-2 2-2 10.4 0 12.4"/>',
  send: '<path d="M14 2 1.8 7l4.6 1.8L14 2 8.2 14l-1.8-5.2"/>',
  chat: '<path d="M8 2.2c3.3 0 6 2.2 6 5s-2.7 5-6 5c-.8 0-1.6-.1-2.3-.4L2.4 13l.9-2.6C2.5 9.5 2 8.4 2 7.2c0-2.8 2.7-5 6-5z"/>',
  play: '<rect x="1.8" y="3" width="12.4" height="10" rx="2"/><path d="M6.6 5.8v4.4L10.2 8z" fill="currentColor"/>',
  music: '<path d="M6 12.2V3.4l6.4-1.4v8.6"/><circle cx="4.4" cy="12.2" r="1.6"/><circle cx="10.8" cy="10.6" r="1.6"/>',
  warn: '<path d="M8 2 14.4 13.4H1.6z"/><path d="M8 6.4v3.2M8 11.4v.2"/>',
  check: '<path d="M3 8.4 6.4 11.6 13 4.6"/>',
  checkc: '<circle cx="8" cy="8" r="6.2"/><path d="M5.2 8.2 7.2 10.2 10.8 6"/>',
  refresh: '<path d="M13.2 6.4A5.4 5.4 0 1 0 13 10"/><path d="M13.6 2.6v3.8H9.8"/>',
  gear: '<path d="M12.59 6.97 L14.25 7.18 L14.25 8.82 L12.59 9.03 L11.97 10.52 L12.99 11.84 L11.84 12.99 L10.52 11.97 L9.03 12.59 L8.82 14.25 L7.18 14.25 L6.97 12.59 L5.48 11.97 L4.16 12.99 L3.01 11.84 L4.03 10.52 L3.41 9.03 L1.75 8.82 L1.75 7.18 L3.41 6.97 L4.03 5.48 L3.01 4.16 L4.16 3.01 L5.48 4.03 L6.97 3.41 L7.18 1.75 L8.82 1.75 L9.03 3.41 L10.52 4.03 L11.84 3.01 L12.99 4.16 L11.97 5.48Z"/><circle cx="8" cy="8" r="2"/>',
  more: '<circle cx="3.4" cy="8" r=".9" fill="currentColor"/><circle cx="8" cy="8" r=".9" fill="currentColor"/><circle cx="12.6" cy="8" r=".9" fill="currentColor"/>',
  pause: '<path d="M5.6 3.4v9.2M10.4 3.4v9.2"/>',
  plus: '<path d="M8 3v10M3 8h10"/>',
  search: '<circle cx="7" cy="7" r="4.4"/><path d="M10.3 10.3 14 14"/>',
  list: '<path d="M5.6 4h8M5.6 8h8M5.6 12h8"/><circle cx="2.6" cy="4" r=".7" fill="currentColor"/><circle cx="2.6" cy="8" r=".7" fill="currentColor"/><circle cx="2.6" cy="12" r=".7" fill="currentColor"/>',
  branch: '<path d="M8 14V8.4M8 8.4 3.4 2.6M8 8.4l4.6-5.8M3.4 2.6v2.6M3.4 2.6H6M12.6 2.6v2.6M12.6 2.6H10"/>',
  activity: '<rect x="1.8" y="2.6" width="12.4" height="10.8" rx="2"/><path d="M3.6 8.6h2l1.4-3 2 5 1.4-2h2"/>',
  info: '<circle cx="8" cy="8" r="6.2"/><path d="M8 7.2v4M8 4.8v.2"/>',
  pencil: '<path d="M10.6 2.8 13.2 5.4 5.6 13H3v-2.6z"/>',
  trash: '<path d="M2.8 4.2h10.4M6.2 4.2V2.6h3.6v1.6M4 4.2l.7 9.2h6.6l.7-9.2"/>',
  xc: '<circle cx="8" cy="8" r="6.2"/><path d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4"/>',
  shield: '<path d="M8 1.8 13.2 3.8V8c0 3-2.2 5.2-5.2 6.2C5 13.2 2.8 11 2.8 8V3.8z"/>',
  key: '<circle cx="8" cy="5.2" r="3.2"/><path d="M8 8.4V14M8 11.2h2M8 13h1.6"/>',
  out: '<path d="M4 12 12 4M6 4h6v6"/>',
  power: '<path d="M8 1.8v6M4.6 3.8a5.4 5.4 0 1 0 6.8 0"/>',
  compass: '<circle cx="8" cy="8" r="6.2"/><path d="M10.6 5.4 9 9 5.4 10.6 7 7z"/>',
  grid: '<rect x="2.2" y="2.2" width="4.8" height="4.8" rx="1"/><rect x="9" y="2.2" width="4.8" height="4.8" rx="1"/><rect x="2.2" y="9" width="4.8" height="4.8" rx="1"/><rect x="9" y="9" width="4.8" height="4.8" rx="1"/>',
  logs: '<rect x="2" y="2.6" width="12" height="10.8" rx="1.6"/><path d="M4.6 5.6h6.8M4.6 8h6.8M4.6 10.4h4"/>',
  sliders: '<path d="M2.4 4.6h11.2M2.4 11.4h11.2"/><circle cx="5.6" cy="4.6" r="1.6" fill="#0F0F14"/><circle cx="10.4" cy="11.4" r="1.6" fill="#0F0F14"/>',
  book: '<path d="M8 4c-1.6-1.2-3.6-1.6-5.8-1.4v10c2.2-.2 4.2.2 5.8 1.4 1.6-1.2 3.6-1.6 5.8-1.4v-10C11.6 2.4 9.6 2.8 8 4zM8 4v10"/>',
  chev: '<path d="M4.6 6.4 8 9.8l3.4-3.4"/>',
  chevr: '<path d="M6.4 4.4 9.8 8l-3.4 3.6"/>',
  tray: '<path d="M2.2 9.4 4 3.4h8l1.8 6v3.2H2.2zM2.2 9.4h3.4l.8 1.6h3.2l.8-1.6h3.4"/>',
  lock: '<rect x="3.4" y="7" width="9.2" height="6.6" rx="1.4"/><path d="M5.4 7V5a2.6 2.6 0 0 1 5.2 0v2"/>',
};
for (const el of document.querySelectorAll('i[data-g]')) {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 16 16');
  s.setAttribute('fill', 'none'); s.setAttribute('stroke', 'currentColor');
  s.setAttribute('stroke-width', el.dataset.w || '1.3');
  s.setAttribute('stroke-linecap', 'round'); s.setAttribute('stroke-linejoin', 'round');
  s.setAttribute('class', 'g ' + el.className);
  if (el.style.cssText) s.setAttribute('style', el.style.cssText);
  s.innerHTML = P[el.dataset.g] || '';
  el.replaceWith(s);
}
