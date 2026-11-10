const notes = [
  { title: 'Moral message in “A Christmas Carol”', date: 'Nov 6, 2026 at 10:24 AM', detail: 'Canvas · 2 cards', cardTitle: 'This weeks tip.', cardBody: 'Notesy Canvas.\nAdd attachments with', cardCount: 2, arrows: [{ x1: .45, y1: .38, x2: .54, y2: .38 }] },
  { title: 'Western culture', date: 'Nov 5, 2026 at 7:40 AM', detail: 'Canvas · 1 card', cardTitle: 'Western culture', cardBody: 'Core concepts in Western culture\nOrigins: rooted in ancient Greece and Rome.\nThree pillars: philosophy, Christianity, and empiricism.\n\nA note can keep growing while it stays easy to find.', cardCount: 1, arrows: [] },
];
let currentNote = 0;
let cardCount = 2;
let zoom = 100;
let nextCard = 0;
let activeFolder = 'Notes';
let freeArrows = [];
let arrowMode = false;
let arrowDraft = null;
let toastTimer;
const notesList = document.querySelector('#notes');
const canvasCards = document.querySelector('#canvas-cards');
const canvasSpace = document.querySelector('#canvas-space');
const connectors = document.querySelector('#connectors');
const toast = document.querySelector('#toast');
const demoWindow = document.querySelector('#demo-window');

function escapeHTML(value) {
  return value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
}
function showToast(message) {
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 2100);
}
function visibleNotes() {
  const query = document.querySelector('#search').value.trim().toLowerCase();
  return notes.map((note, index) => ({ note, index })).filter(({ note }) => {
    const folderMatch = activeFolder === 'All iCloud' || activeFolder === 'Notes' || note.quick === true || note.detail.includes('Canvas');
    return folderMatch && (!query || note.title.toLowerCase().includes(query) || note.cardBody.toLowerCase().includes(query));
  });
}
function renderNotes() {
  notesList.innerHTML = '';
  const matches = visibleNotes();
  document.querySelector('#empty-search').classList.toggle('show', matches.length === 0);
  matches.forEach(({ note, index }) => {
    const row = document.createElement('button');
    row.className = `note-row${index === currentNote ? ' selected' : ''}`;
    row.innerHTML = `<strong>${escapeHTML(note.title)}</strong><span>${escapeHTML(note.date)}</span><small>${escapeHTML(note.detail)}</small>`;
    row.addEventListener('click', () => selectNote(index));
    notesList.append(row);
  });
}
function selectNote(index) {
  if (!notes[index]) return;
  currentNote = index;
  const note = notes[index];
  document.querySelector('#text-title').textContent = note.title;
  document.querySelector('#text-date').textContent = note.date;
  document.querySelector('#text-body').innerHTML = `<p>${escapeHTML(note.cardBody).replaceAll('\n', '<br>')}</p>`;
  document.querySelector('#view-title').textContent = activeFolder === 'Canvas' ? 'Canvas' : 'Notes';
  renderNotes();
  renderCanvas(note);
}
function renderCanvas(note = notes[currentNote]) {
  cardCount = note.cardCount || 1;
  canvasCards.innerHTML = '';
  freeArrows = note.arrows || [];
  const primary = createCard(note.cardTitle, note.cardBody, 8, 22, 'card-primary');
  primary.classList.add('focused');
  if (cardCount > 1) {
    createCard('Western culture', 'Core concepts in Western culture\nOrigins in ancient Greece and Rome\nThree pillars: philosophy, Christianity, empiricism', 56, 21, 'card-secondary').classList.add('focused');
  }
  renderArrows();
}
function createCard(title, body, left, top, extraClass = '') {
  const card = document.createElement('article');
  card.className = `canvas-card ${extraClass}`;
  card.style.left = `${left}%`;
  card.style.top = `${top}%`;
  card.dataset.x = left;
  card.dataset.y = top;
  const content = extraClass.includes('card-secondary')
    ? `<div class="embedded-window"><div class="embedded-toolbar"><i></i><i></i><i></i><span></span><b>Notes</b></div><h3>${escapeHTML(title)}</h3><small>Nov 5, 2026 at 7:40 AM · Canvas</small><div class="embedded-copy">${escapeHTML(body)}</div></div>`
    : `<h3 contenteditable="true" aria-label="Canvas card title">${escapeHTML(title)}</h3><div class="card-copy" contenteditable="true" aria-label="Canvas card text">${escapeHTML(body).replaceAll('\n', '<br>')}</div>`;
  card.innerHTML = `<span class="resize-dot dot-top"></span><span class="resize-dot dot-left"></span><span class="resize-dot dot-right"></span><span class="resize-dot dot-bottom"></span>${content}`;
  card.addEventListener('pointerdown', startDrag);
  card.addEventListener('click', () => card.classList.add('focused'));
  canvasCards.append(card);
  return card;
}
function renderArrows() {
  connectors.querySelectorAll('path.free-arrow').forEach(path => path.remove());
  const width = canvasSpace.offsetWidth;
  const height = canvasSpace.offsetHeight;
  freeArrows.forEach(arrow => {
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.classList.add('free-arrow');
    path.setAttribute('d', `M ${arrow.x1 * width} ${arrow.y1 * height} L ${arrow.x2 * width} ${arrow.y2 * height}`);
    path.setAttribute('marker-end', 'url(#arrowhead)');
    connectors.append(path);
  });
}
function arrowPoint(event) {
  const bounds = canvasSpace.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(1, (event.clientX - bounds.left) / bounds.width)),
    y: Math.max(0, Math.min(1, (event.clientY - bounds.top) / bounds.height)),
  };
}
function beginFreeArrow(event) {
  const point = arrowPoint(event);
  arrowDraft = { x1: point.x, y1: point.y, x2: point.x, y2: point.y };
  freeArrows.push(arrowDraft);
  renderArrows();
  event.preventDefault();
  event.stopPropagation();
  event.currentTarget.setPointerCapture(event.pointerId);
  event.currentTarget.addEventListener('pointermove', moveFreeArrow);
  event.currentTarget.addEventListener('pointerup', finishFreeArrow, { once: true });
  event.currentTarget.addEventListener('pointercancel', finishFreeArrow, { once: true });
}
function moveFreeArrow(event) {
  if (!arrowDraft) return;
  const point = arrowPoint(event);
  arrowDraft.x2 = point.x;
  arrowDraft.y2 = point.y;
  renderArrows();
}
function finishFreeArrow(event) {
  event.currentTarget.removeEventListener('pointermove', moveFreeArrow);
  event.currentTarget.removeEventListener('pointerup', finishFreeArrow);
  event.currentTarget.removeEventListener('pointercancel', finishFreeArrow);
  let placed = false;
  if (arrowDraft) {
    const length = Math.hypot(arrowDraft.x2 - arrowDraft.x1, arrowDraft.y2 - arrowDraft.y1);
    if (length < .02) freeArrows.pop();
    else placed = true;
    notes[currentNote].arrows = freeArrows;
  }
  arrowDraft = null;
  arrowMode = false;
  document.querySelector('#connect-cards').classList.remove('active');
  document.querySelector('#connect-cards').setAttribute('aria-pressed', 'false');
  document.querySelector('#canvas-panel').classList.remove('arrow-mode');
  renderArrows();
  if (placed) showToast('Free arrow placed on the canvas.');
}
function toggleArrowMode() {
  arrowMode = !arrowMode;
  const button = document.querySelector('#connect-cards');
  button.classList.toggle('active', arrowMode);
  button.setAttribute('aria-pressed', String(arrowMode));
  document.querySelector('#canvas-panel').classList.toggle('arrow-mode', arrowMode);
  showToast(arrowMode ? 'Hold and drag anywhere on the canvas to place a free arrow.' : 'Arrow tool closed.');
}
let dragState = null;
function startDrag(event) {
  if (event.target.isContentEditable) return;
  const card = event.currentTarget;
  card.classList.add('focused');
  dragState = { card, pointerX: event.clientX, pointerY: event.clientY, left: Number(card.dataset.x), top: Number(card.dataset.y) };
  card.setPointerCapture(event.pointerId);
  card.addEventListener('pointermove', moveCard);
  card.addEventListener('pointerup', stopDrag, { once: true });
}
function moveCard(event) {
  if (!dragState) return;
  const bounds = canvasSpace.getBoundingClientRect();
  const dx = (event.clientX - dragState.pointerX) / bounds.width * 100;
  const dy = (event.clientY - dragState.pointerY) / bounds.height * 100;
  const left = Math.max(0, Math.min(82, dragState.left + dx));
  const top = Math.max(0, Math.min(76, dragState.top + dy));
  dragState.card.style.left = `${left}%`;
  dragState.card.style.top = `${top}%`;
  dragState.card.dataset.x = left;
  dragState.card.dataset.y = top;
}
function stopDrag(event) {
  event.currentTarget.removeEventListener('pointermove', moveCard);
  dragState = null;
}
function addCanvasCard(title = 'A new thought', body = 'Give this idea a little room to grow.') {
  const offset = (nextCard++ % 4) * 4;
  const card = createCard(title, body, 27 + offset, 57 - offset, 'card-added');
  card.classList.add('focused');
  cardCount++;
  notes[currentNote].cardCount = cardCount;
  notes[currentNote].detail = `Canvas · ${cardCount} cards`;
  renderNotes();
  showToast('A new card, ready for your thoughts.');
}
function changeZoom(amount) {
  zoom = Math.max(65, Math.min(145, zoom + amount));
  document.querySelector('#zoom-value').textContent = `${zoom}%`;
  canvasSpace.style.transform = `scale(${zoom / 100})`;
}
document.querySelectorAll('.folder-row').forEach(button => button.addEventListener('click', () => {
  document.querySelector('.folder-row.active')?.classList.remove('active');
  button.classList.add('active');
  activeFolder = button.dataset.folder;
  document.querySelector('#view-title').textContent = activeFolder === 'Canvas' ? 'Canvas' : activeFolder;
  document.querySelector('#canvas-panel').classList.toggle('hidden', activeFolder === 'Quick Notes');
  document.querySelector('#text-panel').classList.toggle('hidden', activeFolder !== 'Quick Notes');
  if (activeFolder === 'Quick Notes') document.querySelector('#text-title').textContent = 'Quick Note';
  renderNotes();
}));
document.querySelector('#toggle-sidebar').addEventListener('click', () => document.querySelector('.workspace').classList.toggle('sidebar-collapsed'));
document.querySelector('#toggle-toolbar').addEventListener('click', () => demoWindow.classList.toggle('toolbar-collapsed'));
document.querySelector('#restore-toolbar').addEventListener('click', () => demoWindow.classList.remove('toolbar-collapsed'));
document.querySelector('#add-folder').addEventListener('click', () => {
  const folderName = `New Folder ${document.querySelectorAll('.folder-row').length - 3}`;
  const row = document.createElement('button');
  row.className = 'folder-row';
  row.dataset.folder = folderName;
  row.innerHTML = `<span class="folder-symbol">▱</span>${escapeHTML(folderName)}`;
  document.querySelector('#sidebar').insertBefore(row, document.querySelector('.side-status'));
  row.addEventListener('click', () => {
    document.querySelector('.folder-row.active')?.classList.remove('active');
    row.classList.add('active');
    activeFolder = folderName;
    renderNotes();
  });
  showToast('A new folder is ready.');
});
document.querySelector('#new-note').addEventListener('click', () => {
  notes.unshift({ title: 'A new note', date: 'Nov 6, 2026 just now', detail: 'Quick Note', folder: 'Quick Notes', quick: true, cardTitle: 'A new thought', cardBody: 'Start wherever you are.' });
  currentNote = 0;
  activeFolder = 'Quick Notes';
  document.querySelectorAll('.folder-row').forEach(row => row.classList.toggle('active', row.dataset.folder === activeFolder));
  document.querySelector('#canvas-panel').classList.add('hidden');
  document.querySelector('#text-panel').classList.remove('hidden');
  document.querySelector('#view-title').textContent = 'Quick Note';
  document.querySelector('#text-title').textContent = 'A new note';
  document.querySelector('#text-body').innerHTML = '<p>Start typing your thought here…</p>';
  renderNotes();
  showToast('A fresh note, ready when you are.');
});
document.querySelector('#add-card').addEventListener('click', () => addCanvasCard());
document.querySelector('#connect-cards').addEventListener('click', toggleArrowMode);
document.querySelector('#canvas-panel').addEventListener('pointerdown', event => {
  if (event.target.closest('.zoom-hud')) return;
  if (event.altKey || arrowMode) beginFreeArrow(event);
}, true);
document.querySelector('#zoom-in').addEventListener('click', () => changeZoom(10));
document.querySelector('#zoom-out').addEventListener('click', () => changeZoom(-10));
document.querySelector('#hud-zoom-in').addEventListener('click', () => changeZoom(10));
document.querySelector('#hud-zoom-out').addEventListener('click', () => changeZoom(-10));
document.querySelector('#delete-card').addEventListener('click', () => {
  const cards = [...canvasCards.querySelectorAll('.canvas-card')];
  if (cards.length <= 1) { showToast('Keep at least one thought on your canvas.'); return; }
  cards.at(-1).remove(); cardCount = Math.max(1, cardCount - 1);
  notes[currentNote].cardCount = cardCount;
  notes[currentNote].detail = `Canvas · ${cardCount} cards`;
  renderNotes(); showToast('Card removed from this demo canvas.');
});
document.querySelector('#search').addEventListener('input', renderNotes);
document.querySelector('#toggle-theme').addEventListener('click', () => {
  demoWindow.classList.toggle('dark-demo');
  showToast(demoWindow.classList.contains('dark-demo') ? 'Evening mode.' : 'Back to the light.');
});
document.querySelector('#format-text').addEventListener('click', () => showToast('Select a card title to give it a little emphasis.'));
document.querySelector('#add-checklist').addEventListener('click', () => addCanvasCard('A little checklist', '☐ Make a note\n☐ Add one more thought'));
document.querySelector('#add-table').addEventListener('click', () => addCanvasCard('A small table', 'Idea         | Next step\nOne thought | Let it grow'));
document.querySelector('#attach-file').addEventListener('click', () => showToast('Attachments can live right on a canvas card.'));
document.querySelector('#import-notes').addEventListener('click', () => showToast('Import from Apple Notes is available in Notesy for Mac. Your originals stay in Apple Notes.'));
document.querySelector('#share-note').addEventListener('click', () => showToast('Your note is ready to share from Notesy.'));
window.addEventListener('resize', () => {
  renderArrows();
});
renderNotes();
renderCanvas();
