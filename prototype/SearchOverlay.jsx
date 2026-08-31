function SearchOverlay({ open, onClose }) {
  if (!open) return null;
  const contacts = [{ n: 'Priya Nair', e: 'priya@heypigeon.app' }, { n: 'Sam Okoye', e: 'sam@heypigeon.app' }, { n: 'Ana Torres', e: 'ana@heypigeon.app' }];
  return React.createElement('div', { style: { position: 'fixed', inset: 0, background: 'var(--surface-card)', zIndex: 60, padding: '24px 32px' } },
    React.createElement('div', { style: { display: 'flex', alignItems: 'center', gap: 12, borderBottom: '1px solid var(--border-subtle)', paddingBottom: 14, marginBottom: 20 } },
      React.createElement('input', { autoFocus: true, placeholder: 'Search', style: { flex: 1, border: 'none', outline: 'none', fontFamily: 'var(--font-body)', fontSize: 20, color: 'var(--text-primary)' } }),
      React.createElement('button', { onClick: onClose, style: { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)' } },
        React.createElement('svg', { width: 16, height: 16, viewBox: '0 0 24 24', fill: 'none' }, React.createElement('path', { d: 'M6 6l12 12M18 6L6 18', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round' }))
      )
    ),
    contacts.map((c, i) => React.createElement('div', { key: i, style: { display: 'flex', gap: 16, padding: '9px 0', fontFamily: 'var(--font-body)', fontSize: 14 } },
      React.createElement('span', { style: { color: 'var(--text-primary)', fontWeight: 500 } }, c.n),
      React.createElement('span', { style: { color: 'var(--text-tertiary)' } }, c.e)
    ))
  );
}
window.SearchOverlay = SearchOverlay;
