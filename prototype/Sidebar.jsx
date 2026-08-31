function BurgerButton({ onClick }) {
  const Icon = (d) => <svg width="17" height="17" viewBox="0 0 24 24" fill="none"><path d={d} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
  return <button onClick={onClick} title="Toggle sidebar" style={{ border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex' }}
    onMouseEnter={(ev) => { ev.currentTarget.style.color = 'var(--text-primary)'; }} onMouseLeave={(ev) => { ev.currentTarget.style.color = 'var(--text-tertiary)'; }}>{Icon('M4 7h16M4 12h16M4 17h16')}</button>;
}

function AccountSwitcher({ accounts, activeId, unified, onSelectAccount, onToggleUnified }) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef(null);
  React.useEffect(() => {
    const onDoc = (ev) => { if (ref.current && !ref.current.contains(ev.target)) setOpen(false); };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, []);
  const active = accounts.find((a) => a.id === activeId) || accounts[0];
  const initials = (s) => s.split(/[@.\s]/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('');
  const avatar = (a, size = 28) => (
    <span style={{ width: size, height: size, borderRadius: '50%', background: `var(--tag-${a.tag}-bg)`, color: `var(--tag-${a.tag}-fg)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'var(--font-body)', fontSize: size * 0.4, fontWeight: 700, flexShrink: 0 }}>{initials(a.label)}</span>
  );
  return (
    <div ref={ref} style={{ position: 'relative', marginBottom: 14 }}>
      <button onClick={() => setOpen(!open)} style={{ display: 'flex', alignItems: 'center', gap: 10, width: '100%', border: 'none', background: 'none', cursor: 'pointer', padding: '6px 4px', borderRadius: 'var(--radius-md)' }}
        onMouseEnter={(e) => e.currentTarget.style.background = 'var(--surface-sunken)'} onMouseLeave={(e) => e.currentTarget.style.background = 'none'}>
        {unified
          ? <span style={{ width: 28, height: 28, borderRadius: '50%', background: 'var(--accent-soft)', color: 'var(--text-primary)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><rect x="3" y="3" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="13" y="3" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="3" y="13" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="13" y="13" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/></svg>
            </span>
          : avatar(active)}
        <span style={{ flex: 1, textAlign: 'left', fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 600, color: 'var(--text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{unified ? 'All inboxes' : active.email}</span>
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" style={{ transform: open ? 'rotate(90deg)' : 'none', transition: 'transform 160ms', flexShrink: 0, color: 'var(--text-tertiary)' }}><path d="M9 6l6 6-6 6" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/></svg>
      </button>
      {open && (
        <div style={{ position: 'absolute', top: '100%', left: 0, right: -8, marginTop: 6, background: 'var(--surface-card)', borderRadius: 'var(--radius-lg)', boxShadow: 'var(--shadow-lg)', zIndex: 50, padding: 6, minWidth: 240 }}>
          <button onClick={() => { onToggleUnified(true); setOpen(false); }} style={{ display: 'flex', alignItems: 'center', gap: 10, width: '100%', border: 'none', background: unified ? 'var(--surface-sunken)' : 'none', cursor: 'pointer', padding: '8px 8px', borderRadius: 'var(--radius-md)', textAlign: 'left' }}>
            <span style={{ width: 28, height: 28, borderRadius: '50%', background: 'var(--accent-soft)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text-primary)' }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><rect x="3" y="3" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="13" y="3" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="3" y="13" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/><rect x="13" y="13" width="8" height="8" rx="1.5" stroke="currentColor" strokeWidth="1.8"/></svg>
            </span>
            <span style={{ fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 600, color: 'var(--text-primary)' }}>All inboxes</span>
          </button>
          <div style={{ height: 1, background: 'var(--navy-50)', margin: '6px 4px' }}/>
          {accounts.map((a) => (
            <button key={a.id} onClick={() => { onSelectAccount(a.id); onToggleUnified(false); setOpen(false); }} style={{ display: 'flex', alignItems: 'center', gap: 10, width: '100%', border: 'none', background: (!unified && a.id === activeId) ? 'var(--surface-sunken)' : 'none', cursor: 'pointer', padding: '8px 8px', borderRadius: 'var(--radius-md)', textAlign: 'left' }}>
              {avatar(a)}
              <span style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 600, color: 'var(--text-primary)' }}>{a.label}</div>
                <div style={{ fontFamily: 'var(--font-body)', fontSize: 12.5, color: 'var(--text-tertiary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.email}</div>
              </span>
            </button>
          ))}
          <div style={{ height: 1, background: 'var(--navy-50)', margin: '6px 4px' }}/>
          <button style={{ display: 'flex', alignItems: 'center', gap: 10, width: '100%', border: 'none', background: 'none', cursor: 'pointer', padding: '8px 8px', borderRadius: 'var(--radius-md)', textAlign: 'left', color: 'var(--text-secondary)' }}>
            <span style={{ width: 28, height: 28, borderRadius: '50%', border: '1px dashed var(--border-default)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text-tertiary)' }}>
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none"><path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>
            </span>
            <span style={{ fontFamily: 'var(--font-body)', fontSize: 14 }}>Add account</span>
          </button>
        </div>
      )}
    </div>
  );
}

function Sidebar({ open, onClose, active, onSelect, accounts, activeAccountId, unified, onSelectAccount, onToggleUnified, counts, labels }) {
  const items = [
    { key: 'all', label: 'All emails', d: 'M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1zM3 7l9 6 9-6' },
    { key: 'inbox', label: 'Inbox', d: 'M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z' },
    { key: 'starred', label: 'Starred', d: 'M12 3l2.6 5.6 6.1.6-4.6 4.1 1.3 6-5.4-3.1-5.4 3.1 1.3-6-4.6-4.1 6.1-.6z' },
    { key: 'sent', label: 'Sent', d: 'M4 20l16-8L4 4l2 8-2 8z' },
    { key: 'drafts', label: 'Drafts', d: 'M4 20l1-4L17 4l3 3L8 19l-4 1z' },
    { key: 'archive', label: 'Archive', d: 'M3 7h18M5 7v12a1 1 0 001 1h12a1 1 0 001-1V7M9 11h6' },
    { key: 'scheduled', label: 'Scheduled', d: 'M12 8v4l3 3M12 21a9 9 0 100-18 9 9 0 000 18z' },
    { key: 'spam', label: 'Spam', d: 'M12 9v4m0 4h.01M10.3 3.9L2.9 17a1.8 1.8 0 001.5 2.7h15.2a1.8 1.8 0 001.5-2.7L13.7 3.9a1.8 1.8 0 00-3.4 0z' },
    { key: 'trash', label: 'Trash', d: 'M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13' },
  ];
  return (
    <div style={{
      width: open ? 248 : 0, opacity: open ? 1 : 0, overflow: 'hidden', flexShrink: 0,
      borderRight: open ? '1px solid var(--navy-50)' : 'none', background: 'var(--surface-card)',
      transition: 'width var(--duration-base) var(--ease-standard), opacity var(--duration-base) var(--ease-standard)',
    }}>
      <div style={{ width: 248, display: 'flex', flexDirection: 'column', height: '100%', padding: '18px 14px', boxSizing: 'border-box' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '0 4px 16px' }}>
          <span style={{ flex: 1, fontFamily: 'var(--font-display)', fontWeight: 800, fontSize: 16, color: 'var(--text-primary)' }}>Hey Pigeon</span>
          <button onClick={onClose} title="Close sidebar" style={{ border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex', padding: 4 }}
            onMouseEnter={(ev) => { ev.currentTarget.style.color = 'var(--text-primary)'; }} onMouseLeave={(ev) => { ev.currentTarget.style.color = 'var(--text-tertiary)'; }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M9 4H5a1 1 0 00-1 1v14a1 1 0 001 1h4M15 4h4a1 1 0 011 1v14a1 1 0 01-1 1h-4M9 4v16" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>
          </button>
        </div>
        <AccountSwitcher accounts={accounts} activeId={activeAccountId} unified={unified} onSelectAccount={onSelectAccount} onToggleUnified={onToggleUnified}/>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 1, flex: 1, overflowY: 'auto' }}>
          {items.map((it) => (
            <button key={it.key} onClick={() => onSelect(it.key)} style={{
              display: 'flex', alignItems: 'center', gap: 10, padding: '8px 8px', border: 'none', cursor: 'pointer', textAlign: 'left',
              background: active === it.key ? 'var(--surface-sunken)' : 'none', borderRadius: 'var(--radius-md)',
              color: active === it.key ? 'var(--text-primary)' : 'var(--text-secondary)',
            }}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d={it.d} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>
              <span style={{ flex: 1, fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: active === it.key ? 600 : 400 }}>{it.label}</span>
              {counts && counts[it.key] > 0 && <span style={{ fontFamily: 'var(--font-mono)', fontSize: 12, color: 'var(--text-tertiary)' }}>{counts[it.key]}</span>}
            </button>
          ))}
          <div style={{ height: 1, background: 'var(--navy-50)', margin: '10px 6px' }}/>
          <div style={{ fontFamily: 'var(--font-body)', fontSize: 12, fontWeight: 600, color: 'var(--text-tertiary)', textTransform: 'uppercase', letterSpacing: 0.3, padding: '4px 8px 6px' }}>Labels</div>
          {labels.map((l) => (
            <button key={l.key} onClick={() => onSelect(l.key)} style={{
              display: 'flex', alignItems: 'center', gap: 10, padding: '7px 8px', border: 'none', cursor: 'pointer', textAlign: 'left',
              background: active === l.key ? 'var(--surface-sunken)' : 'none', borderRadius: 'var(--radius-md)',
              color: active === l.key ? 'var(--text-primary)' : 'var(--text-secondary)',
            }}>
              <span style={{ width: 8, height: 8, borderRadius: '50%', background: `var(--tag-${l.tag}-fg)`, flexShrink: 0 }}/>
              <span style={{ fontFamily: 'var(--font-body)', fontSize: 13.5 }}>{l.label}</span>
            </button>
          ))}
        </div>
        <div style={{ height: 1, background: 'var(--navy-50)', margin: '6px 6px 6px' }}/>
        <button onClick={() => onSelect('settings')} style={{
          display: 'flex', alignItems: 'center', gap: 10, padding: '8px 8px', border: 'none', cursor: 'pointer', textAlign: 'left',
          background: active === 'settings' ? 'var(--surface-sunken)' : 'none', borderRadius: 'var(--radius-md)',
          color: active === 'settings' ? 'var(--text-primary)' : 'var(--text-secondary)', flexShrink: 0,
        }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none"><path d="M12 15a3 3 0 100-6 3 3 0 000 6z" stroke="currentColor" strokeWidth="1.6"/><path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09a1.65 1.65 0 00-1-1.51 1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 110-4h.09a1.65 1.65 0 001.51-1 1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06a1.65 1.65 0 001.82.33h0A1.65 1.65 0 0010 3.09V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82v0c.27.6.85 1 1.51 1H21a2 2 0 110 4h-.09a1.65 1.65 0 00-1.51 1z" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>
          <span style={{ flex: 1, fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: active === 'settings' ? 600 : 400 }}>Settings</span>
        </button>
      </div>
    </div>
  );
}
window.BurgerButton = BurgerButton;
window.Sidebar = Sidebar;
