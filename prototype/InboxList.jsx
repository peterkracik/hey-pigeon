window.EMAIL_ACTIONS = [
  { key: 'delete', label: 'Delete', d: 'M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13' },
  { key: 'remind', label: 'Remind me', d: 'M12 8v5l3 2M12 3a9 9 0 100 18 9 9 0 000-18z' },
  { key: 'spam', label: 'Report spam', d: 'M12 9v4m0 4h.01M10.3 3.9L2.7 17a2 2 0 001.7 3h15.2a2 2 0 001.7-3L13.7 3.9a2 2 0 00-3.4 0z' },
  { key: 'reply', label: 'Reply', d: 'M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1' },
  { key: 'pin', label: 'Pin', d: 'M12 3l2.6 5.6 6.1.6-4.6 4.2 1.3 6-5.4-3.2-5.4 3.2 1.3-6-4.6-4.2 6.1-.6z' },
];
const STAR_D = 'M12 3l2.6 5.6 6.1.6-4.6 4.2 1.3 6-5.4-3.2-5.4 3.2 1.3-6-4.6-4.2 6.1-.6z';
const DONE_D = 'M20 6L9 17l-5-5';

function InboxList({ emails, selectedId, onSelect, onOpen, onAction, hoverActions, pinListEnabled }) {
  const { IconButton, Tooltip } = window.VibeMailDesignSystem_b5a4d1;
  const [replyingId, setReplyingId] = React.useState(null);
  React.useEffect(() => { setReplyingId(null); }, [selectedId]);
  const pinned = pinListEnabled ? emails.filter((e) => e.pinned) : [];
  const rest = pinListEnabled ? emails.filter((e) => !e.pinned) : emails;
  const groups = [
    ...(pinned.length ? [{ label: 'Pinned', items: pinned, isPinnedGroup: true }] : []),
    { label: 'Today', items: rest.slice(0, 2) },
    { label: 'Last 7 days', items: rest.slice(2) },
  ];
  const activeActions = (hoverActions && hoverActions.length ? hoverActions : ['done', 'delete', 'pin'])
    .map((k) => window.EMAIL_ACTIONS.find((a) => a.key === k)).filter(Boolean);
  const A = (d) => React.createElement('svg', { width: 15, height: 15, viewBox: '0 0 24 24', fill: 'none' }, React.createElement('path', { d, stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' }));
  const actionBtn = (def, id, isPinned) => {
    const active = def.key === 'pin' && isPinned;
    return React.createElement('button', {
      key: def.key, title: def.label, onClick: (ev) => { ev.stopPropagation(); onAction && onAction(id, def.key); },
      style: { border: 'none', background: 'none', cursor: 'pointer', color: active ? 'var(--blue-600)' : 'var(--text-tertiary)', display: 'flex', padding: 4 },
      onMouseEnter: (ev) => { if (!active) ev.currentTarget.style.color = 'var(--text-primary)'; },
      onMouseLeave: (ev) => { ev.currentTarget.style.color = active ? 'var(--blue-600)' : 'var(--text-tertiary)'; },
    }, React.createElement('svg', { width: 15, height: 15, viewBox: '0 0 24 24', fill: active ? 'currentColor' : 'none' }, React.createElement('path', { d: def.d, stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' })));
  };
  const doneBtn = (e, alwaysVisible) => React.createElement(Tooltip, { label: e.done ? 'Mark not done' : 'Mark done', side: 'bottom' }, React.createElement('button', {
    key: 'done', title: e.done ? 'Mark not done' : 'Mark done', onClick: (ev) => { ev.stopPropagation(); onAction && onAction(e.id, 'done'); },
    className: alwaysVisible || e.done ? 'vm-star is-always' : 'vm-star',
    style: { width: 18, height: 18, flexShrink: 0, border: 'none', background: 'none', padding: 0, cursor: 'pointer', color: e.done ? 'var(--tag-mint-fg)' : 'var(--text-tertiary)', display: 'flex', alignItems: 'center', justifyContent: 'center' },
  }, React.createElement('svg', { width: 15, height: 15, viewBox: '0 0 24 24', fill: 'none' }, React.createElement('path', { d: DONE_D, stroke: 'currentColor', strokeWidth: e.done ? 2.2 : 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' }))));
  return React.createElement('div', null,
    groups.map((g, gi) => React.createElement('div', {
      key: gi, style: g.isPinnedGroup ? { paddingBottom: 24, marginBottom: 20, borderBottom: '1px solid var(--border-subtle)' } : null,
    },
      g.label && React.createElement('div', { style: { padding: '18px 0 8px', fontFamily: 'var(--font-mono)', fontSize: 12, color: 'var(--accent-highlight)', fontWeight: 600 } }, g.label),
      g.items.map((e) => React.createElement('div', {
        key: e.id, style: selectedId === e.id ? { margin: '0 -16px 8px', background: 'var(--surface-card)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', border: '1px solid var(--border-subtle)', overflow: 'hidden' } : null,
      },
      React.createElement('div', {
        onClick: () => onSelect(selectedId === e.id ? null : e.id), className: 'vm-row' + (selectedId === e.id ? ' is-selected' : ''),
        style: {
          display: 'flex', alignItems: 'center', gap: 14, boxSizing: 'border-box', textAlign: 'left', padding: '11px 16px', margin: selectedId === e.id ? 0 : '0 -16px', borderRadius: selectedId === e.id ? 0 : 'var(--radius-md)', cursor: 'pointer',
          borderBottom: 'none', position: 'relative',
        },
      },
        doneBtn(e, false),
        React.createElement('span', { style: { position: 'relative', flexShrink: 0 } },
          React.createElement('span', { style: { width: 26, height: 26, borderRadius: '50%', background: 'var(--surface-sunken)', color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'var(--font-body)', fontSize: 11, fontWeight: 600 } }, e.from.split(' ').filter(Boolean).slice(0,2).map(n=>n[0].toUpperCase()).join('')),
          e.accountTag && React.createElement('span', { title: 'account', style: { position: 'absolute', bottom: -2, right: -2, width: 9, height: 9, borderRadius: '50%', background: `var(--tag-${e.accountTag}-fg)`, border: '1.5px solid var(--surface-card)' } })
        ),
        React.createElement('span', { style: { width: 120, flexShrink: 0, fontFamily: 'var(--font-body)', fontSize: 12.5, fontWeight: e.unread ? 600 : 400, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, e.from),
        React.createElement('span', { style: { display: 'flex', alignItems: 'center', gap: 6, flex: '0 1 auto', minWidth: 60, maxWidth: 270 } },
          React.createElement('span', { style: { width: 6, height: 6, borderRadius: '50%', background: e.labelTag ? `var(--tag-${e.labelTag}-fg)` : 'transparent', flexShrink: 0 } }),
          React.createElement('span', { style: { fontFamily: 'var(--font-body)', fontSize: 12.5, fontWeight: e.unread ? 600 : 400, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, e.subject)
        ),
        React.createElement('span', { style: { flex: '1 1 100px', minWidth: 0, fontFamily: 'var(--font-body)', fontSize: 12.5, color: 'var(--text-tertiary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, e.snippet),
        e.attachment && React.createElement('span', { title: 'Has attachment', style: { flexShrink: 0, color: 'var(--text-tertiary)', display: 'flex' } },
          React.createElement('svg', { width: 14, height: 14, viewBox: '0 0 24 24', fill: 'none' }, React.createElement('path', { d: 'M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' }))
        ),
        React.createElement('span', { style: { position: 'relative', flexShrink: 0, width: selectedId === e.id ? 190 : 118, height: 17 } },
          React.createElement('span', { className: 'vm-row-time', style: { position: 'absolute', inset: 0, fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--text-tertiary)', textAlign: 'right', overflow: 'hidden', whiteSpace: 'nowrap' } }, selectedId === e.id ? (e.fullDate || (e.thread && e.thread[e.thread.length - 1].fullDate) || e.time) : e.time),
          React.createElement('div', { className: 'vm-row-actions', style: { position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 2, opacity: 0 } },
            activeActions.map((def) => actionBtn(def, e.id, e.pinned)),
            React.createElement('button', {
              key: 'open', title: 'Open', onClick: (ev) => { ev.stopPropagation(); onOpen && onOpen(e.id); },
              style: { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex', padding: 4 },
              onMouseEnter: (ev) => { ev.currentTarget.style.color = 'var(--text-primary)'; },
              onMouseLeave: (ev) => { ev.currentTarget.style.color = 'var(--text-tertiary)'; },
            }, A('M9 6l6 6-6 6'))
          )
        )
      ),
      selectedId === e.id && React.createElement('div', {
        style: { padding: '20px 16px 12px' },
      },
          React.createElement('p', { style: { margin: 0, fontFamily: 'var(--font-body)', fontSize: 13, lineHeight: 1.6, color: 'var(--text-secondary)', whiteSpace: 'pre-wrap' } }, e.html ? e.snippet : (e.thread ? e.thread[e.thread.length - 1].body : e.body) || e.snippet),
          React.createElement('div', { style: { display: 'flex', alignItems: 'center', marginTop: 20 } },
            React.createElement('div', { style: { display: 'flex', gap: 2, marginLeft: -6 } },
              React.createElement(Tooltip, { label: 'Reply', side: 'top' }, React.createElement(IconButton, { size: 'sm', icon: A('M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1'), label: 'Reply', onClick: (ev) => { ev.stopPropagation(); setReplyingId(e.id); } })),
              React.createElement(Tooltip, { label: 'Reply all', side: 'top' }, React.createElement(IconButton, { size: 'sm', icon: A('M13 17l-5-5 5-5M6 17l-5-5 5-5M1 12h14a5 5 0 010 10h-1'), label: 'Reply all', onClick: (ev) => { ev.stopPropagation(); setReplyingId(e.id); } })),
              React.createElement(Tooltip, { label: 'Forward', side: 'top' }, React.createElement(IconButton, { size: 'sm', icon: A('M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1'), label: 'Forward' }))
            ),
            React.createElement('div', { style: { flex: 1 } }),
            React.createElement('button', {
              onClick: (ev) => { ev.stopPropagation(); onOpen && onOpen(e.id); },
              style: { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--accent-highlight)', fontFamily: 'var(--font-body)', fontSize: 12.5, fontWeight: 600, display: 'flex', alignItems: 'center', gap: 4, padding: 0 },
            }, 'Open full thread', A('M9 6l6 6-6 6'))
          ),
          replyingId === e.id && React.createElement('div', { onClick: (ev) => ev.stopPropagation() },
            React.createElement(window.InlineReply, { email: { from: e.from }, onCancel: () => setReplyingId(null), onSend: () => setReplyingId(null) })
          )
      )
      ))
    )),
    React.createElement('style', null, '.vm-row{background:transparent;transition:background 120ms}.vm-row:hover{background:var(--surface-card);box-shadow:var(--shadow-xs);border-color:var(--border-subtle) !important}.vm-row.is-selected{background:transparent !important;border-color:transparent !important;box-shadow:none !important}.vm-row-time,.vm-row-actions{transition:opacity 100ms}.vm-row:hover .vm-row-time{opacity:0 !important}.vm-row:hover .vm-row-actions{opacity:1 !important}.vm-star{opacity:0;transition:opacity 100ms,color 100ms}.vm-star.is-pinned,.vm-star.is-always{opacity:1}.vm-row:hover .vm-star,.vm-row.is-selected .vm-star{opacity:1}.vm-star:hover{color:var(--blue-600) !important}')
  );
}
window.InboxList = InboxList;
