function InlineReply({ email, onCancel, onSend }) {
  const { IconButton } = window.VibeMailDesignSystem_b5a4d1;
  const [sent, setSent] = React.useState(false);
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

  const F = (d) => <svg width="14" height="14" viewBox="0 0 24 24" fill="none"><path d={d} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
  const iconBtnStyle = { border: 'none', background: 'none', cursor: 'pointer', color: 'var(--text-tertiary)', display: 'flex', padding: 6, borderRadius: 'var(--radius-sm)' };
  const formatOptions = [
    ['M7 5h6a3.5 3.5 0 010 7H7zM7 12h7a3.5 3.5 0 010 7H7z', 'Bold'],
    ['M10 5h7M7 19h7M13.5 5L9.5 19', 'Italic'],
    ['M6 5v6a6 6 0 0012 0V5M4 19h16', 'Underline'],
    ['M4 12h16M8 6.5c0-1.5 2-2.5 4-2.5s4.5 1 4.5 3-2 2.5-4.5 3-4.5 1.5-4.5 3.5 2 3 4.5 3 4-1 4-2.5', 'Strikethrough'],
    ['M10 14a3.5 3.5 0 005 0l3-3a3.5 3.5 0 00-5-5l-1 1M14 10a3.5 3.5 0 00-5 0l-3 3a3.5 3.5 0 005 5l1-1', 'Link'],
    ['M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01', 'Bulleted list'],
  ];
  const renderToolbar = () => formatOptions.map(([d, label], i) => <IconButton key={i} size="sm" icon={F(d)} label={label}/>);

  if (sent) return <div style={{ padding: '14px 0', fontFamily: 'var(--font-body)', fontSize: 13.5, color: 'var(--text-tertiary)', borderTop: '1px solid var(--border-subtle)' }}>Message sent</div>;
  return (
    <div style={{ marginTop: 20, paddingTop: 16 }}>
      <div style={{ fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-tertiary)' }}>To: {email.from}</div>
      <textarea ref={bodyRef} onSelect={onBodySelect} autoFocus placeholder={`Reply to ${email.from}…`} rows={6} style={{ width: '100%', boxSizing: 'border-box', border: 'none', outline: 'none', resize: 'none', padding: '16px 0 0', fontFamily: 'var(--font-body)', fontSize: 14, color: 'var(--text-primary)' }}/>
      {selPos && <div ref={selRef} style={{ position: 'fixed', top: selPos.top, left: selPos.left, display: 'flex', gap: 2, padding: 6, background: 'var(--surface-card)', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', zIndex: 20 }}>{renderToolbar()}</div>}
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, paddingTop: 14, borderTop: '1px solid var(--border-subtle)', marginTop: 14 }}>
        <button onClick={() => { setSent(true); setTimeout(() => { setSent(false); onSend(); }, 700); }} style={{ border: 'none', background: 'var(--navy-900)', color: 'var(--text-inverse)', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 8, padding: '8px 18px', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-body)', fontWeight: 600, fontSize: 13.5 }}>
          {F('M4 20l1-4L17 4l3 3L8 19l-4 1z')} Send
        </button>
        <IconButton size="sm" icon={F('M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13')} label="Discard" onClick={onCancel}/>
        <div style={{ width: 1, height: 20, background: 'var(--border-subtle)', margin: '0 4px' }}/>
        <IconButton size="sm" icon={F('M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9')} label="Attach file"/>
        <div ref={aaRef} style={{ position: 'relative' }}>
          <button title="Formatting" onClick={() => setShowFormat(!showFormat)} style={{ ...iconBtnStyle, fontFamily: 'var(--font-body)', fontSize: 13, fontWeight: 600, color: showFormat ? 'var(--text-primary)' : 'var(--text-tertiary)' }}>Aa</button>
          {showFormat && <div style={{ position: 'absolute', bottom: 'calc(100% + 8px)', left: 0, display: 'flex', gap: 2, padding: 6, background: 'var(--surface-card)', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', zIndex: 10 }}>{renderToolbar()}</div>}
        </div>
      </div>
    </div>
  );
}

function HtmlEmailFrame({ html }) {
  const ref = React.useRef(null);
  const resize = () => { const w = ref.current; if (w && w.contentWindow) { try { w.style.height = w.contentWindow.document.documentElement.scrollHeight + 'px'; } catch (e) {} } };
  return <iframe ref={ref} srcDoc={html} onLoad={resize} style={{ width: '100%', border: 'none', display: 'block' }} title="email content"/>;
}

function ThreadMessage({ msg, expanded, isLast, onToggle, showActions, onReply, onReplyAll, onForward }) {
  const { IconButton, Tooltip } = window.VibeMailDesignSystem_b5a4d1;
  const A = (d) => <svg width="15" height="15" viewBox="0 0 24 24" fill="none"><path d={d} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
  const name = msg.isMe ? 'Me' : msg.from;
  const initials = name.split(' ').filter(Boolean).slice(0, 2).map((n) => n[0].toUpperCase()).join('');
  const avatar = (size) => <span style={{ width: size, height: size, flexShrink: 0, borderRadius: '50%', background: 'var(--surface-sunken)', color: 'var(--text-secondary)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'var(--font-body)', fontSize: size > 30 ? 12 : 11, fontWeight: 600 }}>{initials}</span>;
  if (!expanded) {
    return (
      <div onClick={onToggle} className="vm-thread-row" style={{ display: 'flex', alignItems: 'center', gap: 12, boxSizing: 'border-box', padding: '11px 16px', margin: '0 -16px', borderRadius: 'var(--radius-md)', cursor: 'pointer', border: '1px solid transparent' }}>
        {avatar(26)}
        <span style={{ width: 110, flexShrink: 0, fontFamily: 'var(--font-body)', fontSize: 14, fontWeight: 500, color: 'var(--text-secondary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{name}</span>
        <span style={{ flex: 1, fontFamily: 'var(--font-body)', fontSize: 14, color: 'var(--text-tertiary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{msg.snippet}</span>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--text-tertiary)', flexShrink: 0 }}>{msg.date}</span>
      </div>
    );
  }
  return (
    <div style={{ margin: '0 -16px 8px', background: 'var(--surface-card)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', border: '1px solid var(--border-subtle)', overflow: 'hidden', padding: '20px 16px 12px' }}>
      <div onClick={onToggle} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, cursor: 'pointer' }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          {avatar(30)}
          <span style={{ fontFamily: 'var(--font-body)', fontSize: 14.5, fontWeight: 700, color: 'var(--text-primary)' }}>{name}</span>
        </span>
        <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5, color: 'var(--text-tertiary)' }}>{msg.fullDate || msg.date}</span>
      </div>
      {msg.html
        ? <HtmlEmailFrame html={msg.body}/>
        : <div style={{ fontFamily: 'var(--font-body)', fontSize: 15, lineHeight: 1.6, color: 'var(--text-secondary)' }}>{msg.body}</div>}
      {msg.attachments && msg.attachments.length > 0 && (
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 24 }}>
          {msg.attachments.map((a, i) => (
            <a key={i} download href="#" style={{ display: 'inline-flex', alignItems: 'center', gap: 8, padding: '8px 12px', border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-md)', fontFamily: 'var(--font-body)', fontSize: 13, color: 'var(--text-secondary)', textDecoration: 'none' }}>
              <svg width="15" height="15" viewBox="0 0 24 24" fill="none"><path d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>
              <span style={{ fontWeight: 600, color: 'var(--text-primary)' }}>{a.name}</span>
              <span style={{ color: 'var(--text-tertiary)' }}>{a.size}</span>
            </a>
          ))}
        </div>
      )}
      {showActions && (
        <div style={{ display: 'flex', gap: 2, marginTop: 14 }}>
          <Tooltip label="Reply" side="top"><IconButton size="sm" icon={A('M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1')} label="Reply" onClick={onReply}/></Tooltip>
          <Tooltip label="Reply all" side="top"><IconButton size="sm" icon={A('M13 17l-5-5 5-5M6 17l-5-5 5-5M1 12h14a5 5 0 010 10h-1')} label="Reply all" onClick={onReplyAll}/></Tooltip>
          <Tooltip label="Forward" side="top"><IconButton size="sm" icon={A('M15 17l5-5-5-5M20 12H9a5 5 0 000 10h1')} label="Forward" onClick={onForward}/></Tooltip>
        </div>
      )}
    </div>
  );
}

window.InlineReply = InlineReply;
function ThreadView({ email, onClose, onReplySent, fullscreen, onToggleFullscreen, onToggleDone }) {
  const { IconButton, Tooltip } = window.VibeMailDesignSystem_b5a4d1;
  const [replyTargetId, setReplyTargetId] = React.useState(null);
  const messages = email ? (email.thread || [{ id: 'm0', from: email.from, isMe: false, date: email.time, fullDate: email.fullDate, snippet: (email.html ? '' : email.body).slice(0, 90), body: email.body, html: email.html, attachments: email.attachments }]) : [];
  const [expandedId, setExpandedId] = React.useState(null);
  React.useEffect(() => { setReplyTargetId(null); setExpandedId(messages.length ? messages[messages.length - 1].id : null); }, [email && email.id]);
  if (!email) return null;
  const A = (d) => <svg width="15" height="15" viewBox="0 0 24 24" fill="none"><path d={d} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></svg>;
  const lastId = messages.length ? messages[messages.length - 1].id : null;
  const content = (
    <div style={{ padding: fullscreen ? '0 28px' : 0, maxWidth: fullscreen ? 720 : undefined, margin: fullscreen ? '0 auto' : undefined }}>
      <h1 style={{ fontFamily: 'var(--font-display)', fontSize: 21, fontWeight: 700, color: 'var(--text-primary)', margin: '0 0 18px' }}>{email.subject}</h1>
      <div>
        {messages.map((m) => (
          <React.Fragment key={m.id}>
            <ThreadMessage msg={m} expanded={expandedId === m.id} isLast={m.id === lastId && replyTargetId !== m.id}
              onToggle={() => setExpandedId(expandedId === m.id ? null : m.id)}
              showActions={replyTargetId !== m.id} onReply={() => setReplyTargetId(m.id)} onReplyAll={() => setReplyTargetId(m.id)} onForward={() => {}}/>
            {replyTargetId === m.id && (
              <div style={{ margin: '0 -16px 8px', background: 'var(--surface-card)', borderRadius: 'var(--radius-md)', boxShadow: 'var(--shadow-md)', border: '1px solid var(--border-subtle)', overflow: 'hidden', padding: '0 16px 14px' }}>
                <InlineReply email={{ from: m.isMe ? email.from : m.from }} onCancel={() => setReplyTargetId(null)} onSend={() => { setReplyTargetId(null); onReplySent && onReplySent(); }}/>
              </div>
            )}
          </React.Fragment>
        ))}
      </div>
      <style>{'.vm-thread-row{transition:background 120ms,box-shadow 120ms}.vm-thread-row:hover{background:var(--surface-card);box-shadow:var(--shadow-xs);border-color:var(--border-subtle) !important}'}</style>
    </div>
  );
  if (fullscreen) {
    const header = (
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginBottom: 20 }}>
        <Tooltip label="Back" side="bottom"><IconButton icon={A('M15 18l-6-6 6-6')} label="Back" onClick={onClose}/></Tooltip>
        <div style={{ flex: 1 }}/>
        <Tooltip label={email.done ? 'Mark not done' : 'Mark done'} side="bottom"><IconButton icon={email.done ? <svg width="15" height="15" viewBox="0 0 24 24" fill="none"><path d="M20 6L9 17l-5-5" stroke="var(--tag-mint-fg)" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/></svg> : A('M20 6L9 17l-5-5')} label="Mark done" onClick={onToggleDone}/></Tooltip>
        <Tooltip label="Delete" side="bottom"><IconButton icon={A('M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13')} label="Delete"/></Tooltip>
        <Tooltip label="Exit full screen" side="bottom">
          <IconButton icon={A('M9 4H5a1 1 0 00-1 1v4M15 4h4a1 1 0 011 1v4M9 20H5a1 1 0 01-1-1v-4M15 20h4a1 1 0 001-1v-4')} label="Exit full screen" onClick={() => onToggleFullscreen(false)}/>
        </Tooltip>
      </div>
    );
    return (
      <div style={{ position: 'fixed', inset: 0, zIndex: 70, background: 'var(--surface-card)', display: 'flex', flexDirection: 'column' }}>
        <div style={{ padding: '18px 28px 0' }}>{header}</div>
        <div style={{ overflowY: 'auto', flex: 1, padding: '0 0 40px' }}>{content}</div>
      </div>
    );
  }
  return content;
}
window.ThreadView = ThreadView;
