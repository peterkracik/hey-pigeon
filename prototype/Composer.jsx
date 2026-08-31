const CONTACTS = [
  { name: 'Priya Nair', email: 'priya.nair@acme.co' },
  { name: 'Sam Okoye', email: 'sam.okoye@gmail.com' },
  { name: 'Ana Torres', email: 'ana.torres@brightbooks.com' },
  { name: 'Marcus Webb', email: 'marcus.webb@webbandpartners.com' },
  { name: 'Jordan Lee', email: 'jordan.lee@linear.app' },
  { name: 'Team', email: 'team@heypigeon.app' },
];

function HighlightMatch({ text, query }) {
  if (!query) return React.createElement('span', { style: { color: 'var(--text-tertiary)' } }, text);
  const i = text.toLowerCase().indexOf(query.toLowerCase());
  if (i === -1) return React.createElement('span', { style: { color: 'var(--text-tertiary)' } }, text);
  return React.createElement('span', null,
    React.createElement('span', { style: { color: 'var(--text-tertiary)' } }, text.slice(0, i)),
    React.createElement('span', { style: { color: 'var(--text-primary)', fontWeight: 600 } }, text.slice(i, i + query.length)),
    React.createElement('span', { style: { color: 'var(--text-tertiary)' } }, text.slice(i + query.length))
  );
}

function RecipientField({ placeholder }) {
  const [chips, setChips] = React.useState([]);
  const [value, setValue] = React.useState('');
  const [open, setOpen] = React.useState(false);
  const [highlight, setHighlight] = React.useState(0);
  const ref = React.useRef(null);
  const inputRef = React.useRef(null);
  React.useEffect(() => {
    const h = (ev) => { if (ref.current && !ref.current.contains(ev.target)) setOpen(false); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, []);
  const matches = value ? CONTACTS.filter((c) => !chips.some((ch) => ch.email === c.email) &&
    (c.name.toLowerCase().includes(value.toLowerCase()) || c.email.toLowerCase().includes(value.toLowerCase()))) : [];
  const addChip = (c) => { setChips([...chips, c]); setValue(''); setOpen(false); setHighlight(0); inputRef.current && inputRef.current.focus(); };
  const isEmail = (s) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.trim());
  const onKeyDown = (ev) => {
    if (ev.key === 'ArrowDown' && matches.length) { ev.preventDefault(); setHighlight((h) => (h + 1) % matches.length); }
    else if (ev.key === 'ArrowUp' && matches.length) { ev.preventDefault(); setHighlight((h) => (h - 1 + matches.length) % matches.length); }
    else if ((ev.key === 'Enter' || ev.key === ',') && value.trim()) {
      ev.preventDefault();
      addChip(matches[highlight] || { name: value.trim(), email: value.trim() });
    } else if (ev.key === ' ' && isEmail(value)) {
      ev.preventDefault();
      addChip({ name: value.trim(), email: value.trim() });
    } else if (ev.key === 'Backspace' && !value && chips.length) {
      setChips(chips.slice(0, -1));
    }
  };
  return React.createElement('div', { ref: ref, style: { position: 'relative', flex: 1, minWidth: 0 } },
    React.createElement('div', { style: { display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 6, minHeight: 22 } },
      chips.map((c, i) => React.createElement('span', { key: c.email, style: { display: 'inline-flex', alignItems: 'center', gap: 5, padding: '3px 4px 3px 10px', background: 'var(--surface-sunken)', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 600, color: 'var(--text-primary)' } },
        c.name,
        React.createElement('button', { onClick: () => setChips(chips.filter((_, j) => j !== i)), style: { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex', padding: 3 } },
          React.createElement('svg', { width: 10, height: 10, viewBox: '0 0 24 24', fill: 'none' }, React.createElement('path', { d: 'M6 6l12 12M18 6L6 18', stroke: 'currentColor', strokeWidth: 2.2, strokeLinecap: 'round' }))
        )
      )),
      React.createElement('input', {
        ref: inputRef, value: value, placeholder: chips.length ? '' : placeholder,
        onChange: (ev) => { setValue(ev.target.value); setOpen(true); setHighlight(0); }, onFocus: () => setOpen(true), onKeyDown: onKeyDown,
        style: { border: 'none', outline: 'none', background: 'none', flex: 1, minWidth: 60, fontFamily: 'var(--font-body)', fontSize: 14, color: 'var(--text-primary)', padding: '2px 0' },
      })
    ),
    open && matches.length > 0 && React.createElement('div', { style: { position: 'absolute', top: '100%', left: 0, right: -400, marginTop: 8, background: 'var(--surface-card)', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-lg)', zIndex: 30, padding: 4, minWidth: 340, maxHeight: 260, overflowY: 'auto' } },
      matches.map((c, i) => React.createElement('button', {
        key: c.email, onClick: () => addChip(c), onMouseEnter: () => setHighlight(i),
        style: { display: 'flex', alignItems: 'baseline', gap: 16, width: '100%', border: 'none', background: i === highlight ? 'var(--surface-sunken)' : 'none', cursor: 'pointer', padding: '9px var(--space-3)', borderRadius: 'var(--radius-sm)', textAlign: 'left' },
      },
        React.createElement('span', { style: { fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 600, color: 'var(--text-primary)', flexShrink: 0, minWidth: 130 } }, React.createElement(HighlightMatch, { text: c.name, query: value })),
        React.createElement('span', { style: { fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-tertiary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, React.createElement(HighlightMatch, { text: c.email, query: value }))
      ))
    )
  );
}

function FieldRow({ label, border, children, alignTop }) {
  return React.createElement('div', { style: { display: 'flex', alignItems: alignTop ? 'flex-start' : 'center', gap: 16, padding: '7px 0', borderBottom: border ? '1px solid var(--border-subtle)' : 'none' } },
    React.createElement('span', { style: { width: 46, flexShrink: 0, fontFamily: 'var(--font-body)', fontSize: 14, color: 'var(--text-tertiary)' } }, label),
    children
  );
}

function Composer({ onClose, onSend }) {
  const { IconButton } = window.VibeMailDesignSystem_b5a4d1;
  const [sent, setSent] = React.useState(false);
  const [showCc, setShowCc] = React.useState(false);
  const [attachments, setAttachments] = React.useState([]);
  const [showFormat, setShowFormat] = React.useState(false);
  const [selPos, setSelPos] = React.useState(null);
  const aaRef = React.useRef(null);
  const selRef = React.useRef(null);
  const bodyRef = React.useRef(null);

  React.useEffect(() => {
    if (!showFormat) return;
    const h = (e) => { if (aaRef.current && !aaRef.current.contains(e.target)) setShowFormat(false); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, [showFormat]);

  React.useEffect(() => {
    if (!selPos) return;
    const h = (e) => { if (selRef.current && !selRef.current.contains(e.target) && e.target !== bodyRef.current) setSelPos(null); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, [selPos]);

  const onBodySelect = () => {
    const ta = bodyRef.current;
    if (!ta || ta.selectionStart === ta.selectionEnd) { setSelPos(null); return; }
    const rect = ta.getBoundingClientRect();
    setSelPos({ top: rect.top - 46, left: rect.left });
  };

  const F = (d) => React.createElement('svg', { width: 14, height: 14, viewBox: '0 0 24 24', fill: 'none' }, React.createElement('path', { d, stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' }));
  const rowStyle = { border: 'none', outline: 'none', padding: '13px 0', fontFamily: 'var(--font-body)', fontSize: 14, color: 'var(--text-primary)', width: '100%', background: 'none', boxSizing: 'border-box' };
  const iconBtnStyle = { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex', padding: 6, borderRadius: 'var(--radius-sm)' };

  const send = () => { setSent(true); setTimeout(() => { setSent(false); onSend(); }, 700); };

  if (sent) {
    return React.createElement('div', { style: { fontFamily: 'var(--font-body)', fontSize: 14, color: 'var(--text-secondary)', padding: 'var(--space-8) 0', textAlign: 'center', borderTop: '1px solid var(--border-subtle)' } }, 'Message sent');
  }

  const formatOptions = [
    ['M7 5h6a3.5 3.5 0 010 7H7zM7 12h7a3.5 3.5 0 010 7H7z', 'Bold'],
    ['M10 5h7M7 19h7M13.5 5L9.5 19', 'Italic'],
    ['M6 5v6a6 6 0 0012 0V5M4 19h16', 'Underline'],
    ['M4 12h16M8 6.5c0-1.5 2-2.5 4-2.5s4.5 1 4.5 3-2 2.5-4.5 3-4.5 1.5-4.5 3.5 2 3 4.5 3 4-1 4-2.5', 'Strikethrough'],
    ['M10 14a3.5 3.5 0 005 0l3-3a3.5 3.5 0 00-5-5l-1 1M14 10a3.5 3.5 0 00-5 0l-3 3a3.5 3.5 0 005 5l1-1', 'Link'],
    ['M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01', 'Bulleted list'],
  ];

  const renderToolbar = () => formatOptions.map(([d, label], i) => React.createElement(IconButton, { key: i, size: 'sm', icon: F(d), label: label }));

  return React.createElement(React.Fragment, null,
    React.createElement(FieldRow, { label: 'To', border: false },
      React.createElement(RecipientField, { placeholder: '' }),
      !showCc && React.createElement('button', { onClick: () => setShowCc(true), style: { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', fontFamily: 'var(--font-body)', fontSize: 13, flexShrink: 0 } }, 'Cc/Bcc')
    ),
    showCc && React.createElement(FieldRow, { label: 'Cc', border: false }, React.createElement(RecipientField, { placeholder: '' })),
    showCc && React.createElement(FieldRow, { label: 'Bcc', border: false }, React.createElement(RecipientField, { placeholder: '' })),
    React.createElement(FieldRow, { label: 'Subject', border: true },
      React.createElement('input', { placeholder: '', style: { border: 'none', outline: 'none', background: 'none', flex: 1, fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 600, color: 'var(--text-primary)' } })
    ),
    React.createElement('textarea', { ref: bodyRef, onSelect: onBodySelect, placeholder: 'Write your message...', rows: 14, style: { ...rowStyle, paddingTop: 24, resize: 'none', flex: 1, minHeight: 260 } }),
    selPos && React.createElement('div', { ref: selRef, style: { position: 'fixed', top: selPos.top, left: selPos.left, display: 'flex', gap: 2, padding: 6, background: 'var(--surface-card)', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', zIndex: 20 } },
      renderToolbar()
    ),
    attachments.length > 0 && React.createElement('div', { style: { display: 'flex', gap: 'var(--space-2)', flexWrap: 'wrap', padding: '0 0 var(--space-3)' } },
      attachments.map((a, i) => React.createElement('span', { key: i, style: { display: 'inline-flex', alignItems: 'center', gap: 6, padding: '5px 10px', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', fontFamily: 'var(--font-body)', fontSize: 12.5, color: 'var(--text-secondary)' } },
        F('M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9'),
        a,
        React.createElement('button', { onClick: () => setAttachments(attachments.filter((_, j) => j !== i)), style: { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex' } }, F('M6 6l12 12M18 6L6 18'))
      ))
    ),
    React.createElement('div', { style: { display: 'flex', alignItems: 'center', gap: 'var(--space-2)', padding: '14px 0', borderTop: '1px solid var(--border-subtle)', position: 'sticky', bottom: 0, background: 'var(--surface-card)' } },
      React.createElement('button', { onClick: send, style: { border: 'none', background: 'var(--navy-900)', color: 'var(--text-inverse)', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 'var(--space-2)', padding: '8px 18px', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-body)', fontWeight: 600, fontSize: 13.5 } },
        F('M4 20l1-4L17 4l3 3L8 19l-4 1z'), 'Send'
      ),
      React.createElement(IconButton, { size: 'sm', icon: F('M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13'), label: 'Discard', onClick: onClose }),
      React.createElement('div', { style: { width: 1, height: 20, background: 'var(--border-subtle)', margin: '0 var(--space-1)' } }),
      React.createElement(IconButton, { size: 'sm', icon: F('M12 7v5l3 3M12 22a10 10 0 100-20 10 10 0 000 20z'), label: 'Send later' }),
      React.createElement(IconButton, { size: 'sm', icon: F('M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9'), label: 'Attach file', onClick: () => setAttachments([...attachments, 'file-' + (attachments.length + 1) + '.pdf']) }),
      React.createElement('div', { ref: aaRef, style: { position: 'relative' } },
        React.createElement('button', { title: 'Formatting', onClick: () => setShowFormat(!showFormat), style: { ...iconBtnStyle, fontFamily: 'var(--font-body)', fontSize: 13, fontWeight: 600, color: showFormat ? 'var(--text-primary)' : 'var(--text-tertiary)' } }, 'Aa'),
        showFormat && React.createElement('div', { style: { position: 'absolute', bottom: 'calc(100% + 8px)', left: 0, display: 'flex', gap: 2, padding: 6, background: 'var(--surface-card)', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', zIndex: 10 } },
          renderToolbar()
        )
      )
    )
  );
}
window.Composer = Composer;
