function CommandPalette({ open, onClose, onAction }) {
  const [query, setQuery] = React.useState('');
  const [index, setIndex] = React.useState(0);
  const inputRef = React.useRef(null);
  const COMMANDS = [
    { key: 'done', label: 'Mark done', shortcut: 'E', d: 'M20 6L9 17l-5-5' },
    { key: 'remind', label: 'Remind me', shortcut: 'H', d: 'M12 7v5l3 3M12 22a10 10 0 100-20 10 10 0 000 20z' },
    { key: 'star', label: 'Star', shortcut: 'S', d: 'M12 3l2.6 5.6 6.1.6-4.6 4.1 1.3 6-5.4-3.1-5.4 3.1 1.3-6-4.6-4.1 6.1-.6z' },
    { key: 'move', label: 'Move to folder', shortcut: 'V', d: 'M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z' },
    { key: 'label', label: 'Add label', shortcut: 'L', d: 'M20.6 12.3l-8-8A2 2 0 0011.2 3.7L4 4v7.2a2 2 0 00.6 1.4l8 8a2 2 0 002.8 0l5.2-5.2a2 2 0 000-2.8zM8 8h.01' },
    { key: 'reply', label: 'Reply', shortcut: 'R', d: 'M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1' },
    { key: 'forward', label: 'Forward', shortcut: 'F', d: 'M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1' },
    { key: 'compose', label: 'Compose new message', shortcut: 'C', d: 'M4 20l1-4L17 4l3 3L8 19l-4 1z' },
    { key: 'inbox', label: 'Go to Inbox', shortcut: 'G I', d: 'M3 12l9-9 9 9M5 10v10h14V10' },
    { key: 'unified', label: 'Go to All Inboxes', shortcut: 'G U', d: 'M3 3h8v8H3zM13 3h8v8h-8zM3 13h8v8H3zM13 13h8v8h-8z' },
    { key: 'delete', label: 'Delete', shortcut: '#', d: 'M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13' },
  ];
  const filtered = COMMANDS.filter((c) => c.label.toLowerCase().includes(query.toLowerCase()));
  React.useEffect(() => { if (open) { setQuery(''); setIndex(0); setTimeout(() => inputRef.current && inputRef.current.focus(), 10); } }, [open]);
  React.useEffect(() => { setIndex(0); }, [query]);
  React.useEffect(() => {
    if (!open) return;
    const onKey = (ev) => {
      if (ev.key === 'Escape') { onClose(); return; }
      if (ev.key === 'ArrowDown') { ev.preventDefault(); setIndex((i) => Math.min(i + 1, filtered.length - 1)); }
      if (ev.key === 'ArrowUp') { ev.preventDefault(); setIndex((i) => Math.max(i - 1, 0)); }
      if (ev.key === 'Enter') { ev.preventDefault(); const c = filtered[index]; if (c) { onAction && onAction(c.key); onClose(); } }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, filtered, index, onClose, onAction]);
  if (!open) return null;
  return (
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, background: 'rgba(11,13,18,0.5)', zIndex: 90, display: 'flex', justifyContent: 'center', alignItems: 'flex-start', paddingTop: '14vh' }}>
      <div onClick={(ev) => ev.stopPropagation()} style={{ width: 560, maxWidth: '90vw', background: 'var(--surface-inverse)', borderRadius: 'var(--radius-2xl)', boxShadow: 'var(--shadow-lg)', overflow: 'hidden' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-3)', padding: 'var(--space-4) var(--space-5)', borderBottom: '1px solid rgba(255,255,255,0.1)' }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" style={{ color: 'rgba(255,255,255,0.5)', flexShrink: 0 }}><circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8"/><path d="M20 20l-4-4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>
          <input ref={inputRef} value={query} onChange={(ev) => setQuery(ev.target.value)} placeholder="Type a command or search…" style={{
            flex: 1, border: 'none', outline: 'none', background: 'none', color: 'var(--text-inverse)', fontFamily: 'var(--font-body)', fontSize: 15,
          }}/>
          <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'rgba(255,255,255,0.35)', border: '1px solid rgba(255,255,255,0.2)', borderRadius: 'var(--radius-sm)', padding: 'var(--space-1) var(--space-2)' }}>ESC</span>
        </div>
        <div style={{ maxHeight: 340, overflowY: 'auto', padding: 'var(--space-2)' }}>
          {filtered.length === 0 && <div style={{ padding: 'var(--space-5)', textAlign: 'center', color: 'rgba(255,255,255,0.4)', fontFamily: 'var(--font-body)', fontSize: 13.5 }}>No matching commands</div>}
          {filtered.map((c, i) => (
            <div key={c.key} onMouseEnter={() => setIndex(i)} onClick={() => { onAction && onAction(c.key); onClose(); }} style={{
              display: 'flex', alignItems: 'center', gap: 'var(--space-3)', padding: 'var(--space-2) var(--space-3)', borderRadius: 'var(--radius-md)', cursor: 'pointer',
              background: i === index ? 'rgba(255,255,255,0.1)' : 'transparent',
            }}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" style={{ color: 'rgba(255,255,255,0.55)', flexShrink: 0 }}><path d={c.d} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>
              <span style={{ flex: 1, fontFamily: 'var(--font-body)', fontSize: 14.5, color: 'var(--text-inverse)' }}>{c.label}</span>
              {c.shortcut.split(' ').map((k, ki) => <span key={ki} style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'rgba(255,255,255,0.6)', background: 'rgba(255,255,255,0.1)', borderRadius: 'var(--radius-sm)', padding: '3px var(--space-2)', minWidth: 18, textAlign: 'center' }}>{k}</span>)}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
window.CommandPalette = CommandPalette;
