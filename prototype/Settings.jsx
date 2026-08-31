function SettingRow({ title, description, control }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 24, padding: '16px 0', borderBottom: '1px solid var(--navy-50)' }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontFamily: 'var(--font-body)', fontSize: 14.5, fontWeight: 600, color: 'var(--text-primary)' }}>{title}</div>
        {description && <div style={{ fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-tertiary)', marginTop: 3, lineHeight: 1.5 }}>{description}</div>}
      </div>
      <div style={{ flexShrink: 0 }}>{control}</div>
    </div>
  );
}

function SettingsGroup({ title, description, children }) {
  return (
    <section style={{ marginBottom: 40 }}>
      <div style={{ marginBottom: 4 }}>
        <h2 style={{ margin: 0, fontFamily: 'var(--font-mono)', fontWeight: 600, fontSize: 12, color: 'var(--accent-highlight)' }}>{title}</h2>
        {description && <p style={{ margin: '4px 0 0', fontFamily: 'var(--font-body)', fontSize: 13.5, color: 'var(--text-tertiary)' }}>{description}</p>}
      </div>
      <div style={{ marginTop: 12 }}>{children}</div>
    </section>
  );
}

function Settings({ accounts, hoverActions, onHoverActionsChange, pinListEnabled, onPinListChange }) {
  const { Switch, Select, Radio, Avatar, Button } = window.VibeMailDesignSystem_b5a4d1;
  const [signature, setSignature] = React.useState('true');
  const [signatureText, setSignatureText] = React.useState('Peter\nHey Pigeon');
  const [dragKey, setDragKey] = React.useState(null);
  const [readReceipts, setReadReceipts] = React.useState(false);
  const [desktopNotif, setDesktopNotif] = React.useState(true);
  const [notifSound, setNotifSound] = React.useState(true);
  const [notifPreview, setNotifPreview] = React.useState('sender-subject');
  const [density, setDensity] = React.useState('comfortable');
  const [theme, setTheme] = React.useState('system');
  const [swipeRight, setSwipeRight] = React.useState('done');
  const [autoAdvance, setAutoAdvance] = React.useState('newer');
  const [blockTracking, setBlockTracking] = React.useState(true);
  const initials = (s) => s.split(/[@.\s]/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('');
  const reorderOrAdd = (targetIndex) => {
    if (!dragKey) return;
    let next = hoverActions.filter((k) => k !== dragKey);
    const insertAt = Math.min(targetIndex, next.length);
    next.splice(insertAt, 0, dragKey);
    if (next.length > 3) next = next.slice(0, 3);
    onHoverActionsChange(next);
    setDragKey(null);
  };

  return (
    <div style={{ width: '100%', paddingBottom: 60 }}>
      <SettingsGroup title="Accounts" description="Connected mailboxes shown in the sidebar.">
        <div style={{ display: 'flex', flexDirection: 'column' }}>
          {accounts.map((a) => (
            <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 0', borderBottom: '1px solid var(--navy-50)' }}>
              <span style={{ width: 32, height: 32, borderRadius: '50%', background: `var(--tag-${a.tag}-bg)`, color: `var(--tag-${a.tag}-fg)`, display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'var(--font-body)', fontSize: 13, fontWeight: 700, flexShrink: 0 }}>{initials(a.label)}</span>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontFamily: 'var(--font-body)', fontSize: 14.5, fontWeight: 600, color: 'var(--text-primary)' }}>{a.label}</div>
                <div style={{ fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-tertiary)' }}>{a.email}</div>
              </div>
              <Button variant="ghost" size="sm">Remove</Button>
            </div>
          ))}
          <div style={{ paddingTop: 14 }}>
            <Button variant="secondary" size="sm">Add account</Button>
          </div>
        </div>
      </SettingsGroup>

      <SettingsGroup title="Notifications">
        <SettingRow title="Desktop notifications" description="Show a system notification for new mail while Hey Pigeon is open." control={<Switch checked={desktopNotif} onChange={(e) => setDesktopNotif(e.target.checked)}/>}/>
        <SettingRow title="Notification sound" description="Play a sound when new mail arrives." control={<Switch checked={notifSound} onChange={(e) => setNotifSound(e.target.checked)}/>}/>
        <SettingRow title="Preview content" description="What to show in a new mail notification." control={
          <Select value={notifPreview} onChange={(e) => setNotifPreview(e.target.value)} options={[
            { value: 'sender-subject', label: 'Sender & subject' },
            { value: 'sender-only', label: 'Sender only' },
            { value: 'none', label: 'Nothing' },
          ]}/>
        }/>
      </SettingsGroup>

      <SettingsGroup title="Appearance">
        <SettingRow title="Theme" description="Match your system, or set Hey Pigeon independently." control={
          <div style={{ display: 'flex', gap: 18 }}>
            {[['system', 'System'], ['light', 'Light'], ['dark', 'Dark']].map(([v, l]) => (
              <Radio key={v} name="theme" label={l} checked={theme === v} onChange={() => setTheme(v)}/>
            ))}
          </div>
        }/>
        <SettingRow title="List density" description="How much space each message row takes up." control={
          <Select value={density} onChange={(e) => setDensity(e.target.value)} options={[
            { value: 'comfortable', label: 'Comfortable' },
            { value: 'compact', label: 'Compact' },
          ]}/>
        }/>
      </SettingsGroup>

      <SettingsGroup title="Inbox" description="Control how messages are grouped and which actions appear on hover.">
        <SettingRow title="Pinned list" description="Group pinned messages at the top of your inbox, above the rest." control={<Switch checked={pinListEnabled} onChange={(e) => onPinListChange(e.target.checked)}/>}/>
        <SettingRow title="Hover actions" description="Drag up to 3 actions into the box to show them when you hover a message." control={null}/>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14, padding: '0 0 16px' }}>
          <div>
            <div style={{ fontFamily: 'var(--font-body)', fontSize: 12, color: 'var(--text-tertiary)', marginBottom: 6 }}>Selected (drag to reorder)</div>
            <div onDragOver={(e) => e.preventDefault()} onDrop={(e) => { e.preventDefault(); reorderOrAdd(hoverActions.length); }}
              style={{ display: 'flex', gap: 8, minHeight: 40, alignItems: 'center', padding: 8, border: '1px dashed var(--border-default)', borderRadius: 'var(--radius-md)' }}>
              {hoverActions.map((k, i) => {
                const a = window.EMAIL_ACTIONS.find((x) => x.key === k);
                if (!a) return null;
                return (
                  <span key={k} draggable onDragStart={() => setDragKey(k)} onDragEnd={() => setDragKey(null)}
                    onDragOver={(e) => { e.preventDefault(); e.stopPropagation(); }} onDrop={(e) => { e.preventDefault(); e.stopPropagation(); reorderOrAdd(i); }}
                    style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 6px 6px 12px', background: 'var(--surface-sunken)', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-body)', fontSize: 13, fontWeight: 600, color: 'var(--text-primary)', cursor: 'grab' }}>
                    {a.label}
                    <button onClick={() => onHoverActionsChange(hoverActions.filter((x) => x !== k))} style={{ border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex', padding: 4 }}>
                      <svg width="11" height="11" viewBox="0 0 24 24" fill="none"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/></svg>
                    </button>
                  </span>
                );
              })}
              {hoverActions.length === 0 && <span style={{ fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-tertiary)' }}>Drop actions here</span>}
            </div>
          </div>
          <div>
            <div style={{ fontFamily: 'var(--font-body)', fontSize: 12, color: 'var(--text-tertiary)', marginBottom: 6 }}>Available</div>
            <div onDragOver={(e) => e.preventDefault()} onDrop={(e) => { e.preventDefault(); if (dragKey) onHoverActionsChange(hoverActions.filter((k) => k !== dragKey)); setDragKey(null); }}
              style={{ display: 'flex', gap: 8, flexWrap: 'wrap', minHeight: 34, padding: 8 }}>
              {window.EMAIL_ACTIONS.filter((a) => !hoverActions.includes(a.key)).map((a) => (
                <span key={a.key} draggable onDragStart={() => setDragKey(a.key)} onDragEnd={() => setDragKey(null)}
                  style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 12px', background: 'var(--surface-card)', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-secondary)', cursor: 'grab' }}>
                  {a.label}
                </span>
              ))}
            </div>
          </div>
        </div>
      </SettingsGroup>

      <SettingsGroup title="Reading & replying">
        <SettingRow title="Include signature" description="Add your signature to new messages automatically." control={<Switch checked={signature === 'true'} onChange={(e) => setSignature(e.target.checked ? 'true' : 'false')}/>}/>
        {signature === 'true' && (
          <div style={{ padding: '0 0 16px' }}>
            <textarea value={signatureText} onChange={(e) => setSignatureText(e.target.value)} rows={4}
              style={{ width: '100%', boxSizing: 'border-box', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', padding: 12, resize: 'vertical', fontFamily: 'var(--font-body)', fontSize: 13.5, color: 'var(--text-primary)', outline: 'none' }}/>
          </div>
        )}
        <SettingRow title="Send read receipts" description="Let senders know when you've opened their message." control={<Switch checked={readReceipts} onChange={(e) => setReadReceipts(e.target.checked)}/>}/>
        <SettingRow title="Swipe right on a message" description="Choose what a right swipe does in the inbox list." control={
          <Select value={swipeRight} onChange={(e) => setSwipeRight(e.target.value)} options={[
            { value: 'done', label: 'Mark done' },
            { value: 'delete', label: 'Delete' },
            { value: 'snooze', label: 'Snooze' },
          ]}/>
        }/>
        <SettingRow title="After archiving or deleting" description="Which message to open next." control={
          <Select value={autoAdvance} onChange={(e) => setAutoAdvance(e.target.value)} options={[
            { value: 'newer', label: 'Newer message' },
            { value: 'older', label: 'Older message' },
            { value: 'list', label: 'Back to list' },
          ]}/>
        }/>
      </SettingsGroup>

      <SettingsGroup title="Privacy">
        <SettingRow title="Block external images by default" description="Stop remote images from loading until you choose to show them, to limit sender tracking." control={<Switch checked={blockTracking} onChange={(e) => setBlockTracking(e.target.checked)}/>}/>
      </SettingsGroup>
    </div>
  );
}
window.Settings = Settings;
