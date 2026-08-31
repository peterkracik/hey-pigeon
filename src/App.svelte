<script lang="ts">
  import Sidebar from "./lib/Sidebar.svelte";
  import InboxList from "./lib/InboxList.svelte";
  import ThreadView from "./lib/ThreadView.svelte";
  import Composer from "./lib/Composer.svelte";
  import SearchOverlay from "./lib/SearchOverlay.svelte";
  import CommandPalette from "./lib/CommandPalette.svelte";
  import Settings from "./lib/Settings.svelte";
  import IconButton from "./lib/ds/IconButton.svelte";
  import Tooltip from "./lib/ds/Tooltip.svelte";
  import Icon from "./lib/ds/Icon.svelte";
  import { ACCOUNTS, EMAILS_SEED, FOLDER_TITLES, LABELS, type Account, type Email, type ThreadMsg } from "./lib/data";
  import * as ipc from "./lib/ipc";

  let sidebarOpen = $state(false);
  let unified = $state(true);
  let activeAccountId = $state("a1");
  let folder = $state("inbox");
  let selectedId: string | null = $state(null);
  let threadOpen = $state(false);
  let composeOpen = $state(false);
  let searchOpen = $state(false);
  let paletteOpen = $state(false);
  let fullscreen = $state(false);
  let composeFullscreen = $state(false);
  let emailsData: Email[] = $state(EMAILS_SEED);
  let hoverActions: string[] = $state(["delete", "pin", "remind"]);
  let pinListEnabled = $state(true);
  let liveAccounts: Account[] = $state([]);

  // Live mode: inside Tauri the mock seed is replaced by real store data.
  async function refreshLive() {
    const [accounts, threads] = await Promise.all([ipc.listAccounts(), ipc.listThreads()]);
    liveAccounts = accounts.map((a) => ({
      id: a.id,
      email: a.email,
      label: a.display_name,
      tag: a.color,
      avatarUrl: a.avatar_url ?? undefined,
      signature: a.signature,
    }));
    // Preserve already-loaded bodies + local flags across refreshes.
    const prev = new Map(emailsData.map((e) => [e.id, e]));
    emailsData = threads.map((t) => {
      const mapped = ipc.threadToEmail(t);
      const old = prev.get(t.id);
      return old?.thread ? { ...mapped, thread: old.thread } : mapped;
    });
    if (liveAccounts.length && !liveAccounts.some((a) => a.id === activeAccountId)) {
      activeAccountId = liveAccounts[0].id;
    }
  }

  $effect(() => {
    if (!ipc.isTauri) return;
    refreshLive().catch((e) => console.error("ipc refresh failed", e));
    let unsub: (() => void) | undefined;
    ipc.onThreadsUpdated(() => {
      refreshLive().catch((e) => console.error("ipc refresh failed", e));
    }).then((u) => (unsub = u));
    return () => unsub?.();
  });

  const accounts = $derived(ipc.isTauri && liveAccounts.length ? liveAccounts : ACCOUNTS);

  const emails = $derived(
    emailsData
      .filter((e) => (folder === "all" ? true : e.folder === folder))
      .filter((e) => unified || e.accountId === activeAccountId)
      .map((e) =>
        unified ? { ...e, accountTag: accounts.find((a) => a.id === e.accountId)?.tag } : e,
      ),
  );
  const email = $derived(
    emails.find((e) => e.id === selectedId) ?? emailsData.find((e) => e.id === selectedId),
  );
  const counts = $derived({
    inbox: emailsData.filter(
      (e) => e.folder === "inbox" && e.unread && (unified || e.accountId === activeAccountId),
    ).length,
  });
  const title = $derived(unified && folder === "inbox" ? "All inboxes" : FOLDER_TITLES[folder]);
  // Compose defaults to the viewed account filter; unified view falls back to the first account.
  const composeFromId = $derived(unified ? accounts[0]?.id : activeAccountId);
  const signatureFor = (accountId: string) => accounts.find((a) => a.id === accountId)?.signature;

  function onEmailAction(id: string, action: string) {
    const em = emailsData.find((e) => e.id === id);
    if (ipc.isTauri && em && (action === "done" || action === "delete")) {
      // Optimistic: drop from the local list now; backend applies + queues outbox.
      emailsData = emailsData.filter((e) => e.id !== id);
      if (selectedId === id) selectedId = null;
      const mutation =
        action === "done"
          ? ({ kind: "archive", thread_id: id } as const)
          : ({ kind: "trash", thread_id: id } as const);
      ipc.mutate(em.accountId, mutation).catch((e) => console.error("mutate failed", e));
      return;
    }
    if (action === "pin") emailsData = emailsData.map((e) => (e.id === id ? { ...e, pinned: !e.pinned } : e));
    else if (action === "done") emailsData = emailsData.map((e) => (e.id === id ? { ...e, done: !e.done } : e));
    else console.log(id, action);
  }

  function sendCompose(data: { accountId: string; to: string[]; cc: string[]; bcc: string[]; subject: string; body: string }) {
    if (!ipc.isTauri) return;
    // Before refreshLive resolves, `accounts` is mock data — a send routed to
    // a mock account id would sit in the outbox failing forever.
    if (!liveAccounts.some((a) => a.id === data.accountId)) {
      console.error("compose account not connected", data.accountId);
      return;
    }
    ipc
      .mutate(data.accountId, {
        kind: "send",
        to: data.to,
        cc: data.cc,
        bcc: data.bcc,
        subject: data.subject,
        body_text: data.body,
        reply_to_thread: null,
      })
      .catch((e) => console.error("send failed", e));
  }

  function sendReply(em: Email, msg: ThreadMsg, body: string) {
    if (!ipc.isTauri) return;
    // Reply goes to the sender of the replied-to message; replying to your own
    // message targets the other participant.
    const to = msg.isMe
      ? (em.thread?.findLast((m) => !m.isMe)?.fromAddr ?? "")
      : (msg.fromAddr ?? "");
    if (!to) {
      console.error("no reply address available");
      return;
    }
    const subject = /^re:/i.test(em.subject) ? em.subject : `Re: ${em.subject}`;
    ipc
      .mutate(em.accountId, {
        kind: "send",
        to: [to],
        cc: [],
        bcc: [],
        subject,
        body_text: body,
        reply_to_thread: em.id,
      })
      .catch((e) => console.error("send failed", e));
  }

  function updateAccount(id: string, fields: { displayName?: string; color?: string; signature?: string }) {
    if (!ipc.isTauri) return;
    ipc.updateAccount(id, fields).catch((e) => console.error("update account failed", e));
  }

  function removeAccount(id: string) {
    if (!ipc.isTauri) return;
    ipc.removeAccount(id).catch((e) => console.error("remove failed", e));
  }

  async function addAccount() {
    if (!ipc.isTauri) return;
    try {
      const email = await ipc.startGmailOauth();
      console.info("connected", email);
      await refreshLive();
    } catch (e) {
      alert(String(e));
    }
  }

  // Fetch bodies + mark read; used by both row-select (preview) and full open,
  // so both always show the same content.
  async function loadBodies(id: string) {
    if (!ipc.isTauri) return;
    const em = emailsData.find((e) => e.id === id);
    if (!em || em.thread) return;
    try {
      const res = await ipc.getThread(id);
      if (res) {
        const myEmail = accounts.find((a) => a.id === em.accountId)?.email ?? "";
        const msgs = ipc.messagesToThreadMsgs(res.messages, myEmail);
        emailsData = emailsData.map((e) => (e.id === id ? { ...e, thread: msgs, unread: false } : e));
        if (!res.thread.is_read) {
          ipc.mutate(em.accountId, { kind: "mark_read", thread_id: id, read: true }).catch(() => {});
        }
      }
    } catch (e) {
      console.error("getThread failed", e);
    }
  }

  function selectEmail(id: string | null) {
    selectedId = id;
    if (id) loadBodies(id);
  }

  function openThread(id: string) {
    selectedId = id;
    threadOpen = true;
    loadBodies(id);
  }

  function selectFolder(f: string) {
    folder = f;
    selectedId = null;
    threadOpen = false;
  }

  // Search hits can be threads outside the inbox list (archived etc.) —
  // merge them in so ThreadView can find the email until the next refresh.
  function openSearchResult(t: ipc.BackendThread) {
    searchOpen = false;
    if (!emailsData.some((e) => e.id === t.id)) {
      emailsData = [...emailsData, ipc.threadToEmail(t)];
    }
    openThread(t.id);
  }

  function onPaletteAction(key: string) {
    if (key === "compose") composeOpen = true;
    else if (key === "inbox") folder = "inbox";
    else if (key === "unified") unified = true;
  }

  function closeCompose() {
    composeOpen = false;
    composeFullscreen = false;
  }

  function isEditable(t: EventTarget | null): boolean {
    const el = t as HTMLElement | null;
    return !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);
  }

  function onKey(ev: KeyboardEvent) {
    if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === "k") {
      ev.preventDefault();
      paletteOpen = true;
      return;
    }
    // List navigation — never while typing or while an overlay owns the keyboard.
    if (isEditable(ev.target) || paletteOpen || searchOpen || composeOpen) return;
    if (ev.key === "Escape") {
      if (threadOpen) {
        threadOpen = false;
        fullscreen = false;
      } else if (selectedId !== null) {
        selectedId = null;
      }
      return;
    }
    if (threadOpen || folder === "settings") return;
    if (ev.key === "e" && selectedId !== null) {
      ev.preventDefault();
      onEmailAction(selectedId, "done");
      return;
    }
    if (ev.key === "#" && selectedId !== null) {
      ev.preventDefault();
      onEmailAction(selectedId, "delete");
      return;
    }
    if (ev.key === "j" || ev.key === "ArrowDown") {
      ev.preventDefault();
      const i = emails.findIndex((e) => e.id === selectedId);
      const next = emails[Math.min(i + 1, emails.length - 1)];
      if (next) selectedId = next.id;
    } else if (ev.key === "k" || ev.key === "ArrowUp") {
      ev.preventDefault();
      const i = emails.findIndex((e) => e.id === selectedId);
      const prev = emails[Math.max(i - 1, 0)];
      if (prev) selectedId = prev.id;
    } else if (ev.key === "Enter" && selectedId !== null) {
      ev.preventDefault();
      threadOpen = true;
    }
  }
</script>

<svelte:document onkeydown={onKey} />

<div class="app">
  <Sidebar
    open={sidebarOpen}
    onClose={() => (sidebarOpen = false)}
    active={folder}
    onSelect={selectFolder}
    {accounts}
    {activeAccountId}
    {unified}
    onSelectAccount={(id) => (activeAccountId = id)}
    onToggleUnified={(v) => (unified = v)}
    onAddAccount={addAccount}
    {counts}
    labels={LABELS}
  />
  {#if !sidebarOpen}
    <div class="burger">
      <button class="burger-btn" title="Toggle sidebar" onclick={() => (sidebarOpen = true)}>
        <Icon d="M4 7h16M4 12h16M4 17h16" size={17} />
      </button>
    </div>
  {/if}

  <div class="main">
    <div class="scroll">
      <div class="column">
        {#if !fullscreen}
          <div class="topbar">
            {#if threadOpen}
              <div class="back">
                <Tooltip label="Back" side="bottom">
                  <IconButton
                    size="sm"
                    label="Back"
                    onclick={() => {
                      threadOpen = false;
                    }}
                  >
                    <Icon d="M15 18l-6-6 6-6" size={15} />
                  </IconButton>
                </Tooltip>
              </div>
            {/if}
            <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
            <span
              class="title"
              class:static={threadOpen}
              onclick={() => {
                if (threadOpen) return;
                folder = "inbox";
                unified = true;
              }}
            >
              {title}
              {#if !threadOpen && folder !== "settings"}
                <span class="count">{emails.length}</span>
              {/if}
            </span>
            <div class="spacer"></div>
            {#if !threadOpen && folder !== "settings"}
              <div class="topbar-actions">
                <button class="cmdk" title="Command palette (Cmd+K)" onclick={() => (paletteOpen = true)}>
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
                    <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.6" />
                    <path d="M20 20l-4-4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
                  </svg>
                  Cmd+K
                </button>
                <Tooltip label="Compose" side="bottom">
                  <IconButton label="Compose" onclick={() => (composeOpen = true)}>
                    <Icon d="M4 20l1-4L17 4l3 3L8 19l-4 1z" size={15} />
                  </IconButton>
                </Tooltip>
                <Tooltip label="Search" side="bottom">
                  <IconButton label="Search" onclick={() => (searchOpen = true)}>
                    <svg width="17" height="17" viewBox="0 0 24 24" fill="none">
                      <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.6" />
                      <path d="M20 20l-4-4" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" />
                    </svg>
                  </IconButton>
                </Tooltip>
              </div>
            {/if}
            {#if threadOpen && email}
              <div class="topbar-actions">
                <Tooltip label={email.done ? "Mark not done" : "Mark done"} side="bottom">
                  <IconButton label="Mark done" onclick={() => onEmailAction(email!.id, "done")}>
                    {#if email.done}
                      <Icon d="M20 6L9 17l-5-5" size={17} strokeWidth={2.2} stroke="var(--tag-mint-fg)" />
                    {:else}
                      <Icon d="M20 6L9 17l-5-5" size={15} />
                    {/if}
                  </IconButton>
                </Tooltip>
                <Tooltip label="Delete" side="bottom">
                  <IconButton label="Delete">
                    <Icon d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" size={15} />
                  </IconButton>
                </Tooltip>
                <Tooltip label="Full screen" side="bottom">
                  <IconButton label="Full screen" onclick={() => (fullscreen = true)}>
                    <Icon d="M8 3H5a2 2 0 00-2 2v3M16 3h3a2 2 0 012 2v3M8 21H5a2 2 0 01-2-2v-3M16 21h3a2 2 0 002-2v-3" size={15} />
                  </IconButton>
                </Tooltip>
              </div>
            {/if}
          </div>
        {/if}
        {#if folder === "settings"}
          <Settings
            {accounts}
            {hoverActions}
            onHoverActionsChange={(next) => (hoverActions = next)}
            {pinListEnabled}
            onPinListChange={(v) => (pinListEnabled = v)}
            onAddAccount={addAccount}
            onRemoveAccount={removeAccount}
            onUpdateAccount={updateAccount}
          />
        {:else if threadOpen}
          <ThreadView
            {email}
            onClose={() => {
              threadOpen = false;
              fullscreen = false;
            }}
            onSendReply={(msg, body) => email && sendReply(email, msg, body)}
            replySignature={email ? signatureFor(email.accountId) : undefined}
            {fullscreen}
            onToggleFullscreen={(v) => (fullscreen = v)}
            onToggleDone={() => email && onEmailAction(email.id, "done")}
          />
        {:else}
          <InboxList
            {emails}
            {selectedId}
            onSelect={selectEmail}
            onOpen={openThread}
            onAction={onEmailAction}
            onSendReply={(em, body) => {
              const target = em.thread?.[em.thread.length - 1];
              if (target) sendReply(em, target, body);
            }}
            signatureFor={(em) => signatureFor(em.accountId)}
            {hoverActions}
            {pinListEnabled}
          />
          {#if emails.length === 0}
            <div class="empty">Nothing here yet</div>
          {/if}
        {/if}
      </div>
    </div>
  </div>

  <SearchOverlay open={searchOpen} onClose={() => (searchOpen = false)} onOpen={openSearchResult} />
  <CommandPalette open={paletteOpen} onClose={() => (paletteOpen = false)} onAction={onPaletteAction} />

  {#if composeOpen}
    {#if composeFullscreen}
      <div class="compose-fs">
        <div class="compose-fs-head">
          <span class="compose-fs-title">New message</span>
          <Tooltip label="Exit full screen" side="bottom">
            <IconButton label="Exit full screen" onclick={() => (composeFullscreen = false)}>
              <Icon d="M9 4H5a1 1 0 00-1 1v4M15 4h4a1 1 0 011 1v4M9 20H5a1 1 0 01-1-1v-4M15 20h4a1 1 0 001-1v-4" size={15} />
            </IconButton>
          </Tooltip>
          <Tooltip label="Close" side="bottom">
            <IconButton label="Close" onclick={closeCompose}>
              <Icon d="M6 6l12 12M18 6L6 18" size={15} />
            </IconButton>
          </Tooltip>
        </div>
        <div class="compose-fs-scroll">
          <div class="compose-fs-column">
            <Composer onClose={closeCompose} onSend={sendCompose} {accounts} initialAccountId={composeFromId} />
          </div>
        </div>
      </div>
    {:else}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="compose-backdrop"
        onmousedown={(ev) => {
          if (ev.target === ev.currentTarget) composeOpen = false;
        }}
      >
        <div class="compose-modal">
          <div class="compose-head">
            <span class="compose-title">New message</span>
            <Tooltip label="Full screen" side="bottom">
              <IconButton size="sm" label="Full screen" onclick={() => (composeFullscreen = true)}>
                <Icon d="M8 3H5a2 2 0 00-2 2v3M16 3h3a2 2 0 012 2v3M8 21H5a2 2 0 01-2-2v-3M16 21h3a2 2 0 002-2v-3" size={15} />
              </IconButton>
            </Tooltip>
            <Tooltip label="Close" side="bottom">
              <IconButton size="sm" label="Close" onclick={closeCompose}>
                <Icon d="M6 6l12 12M18 6L6 18" size={15} />
              </IconButton>
            </Tooltip>
          </div>
          <div class="compose-body">
            <div class="compose-body-inner">
              <Composer onClose={closeCompose} onSend={sendCompose} {accounts} initialAccountId={composeFromId} />
            </div>
          </div>
        </div>
      </div>
    {/if}
  {/if}
</div>

<style>
  .app {
    height: 100%;
    display: flex;
    font-family: var(--font-body);
    background: var(--bg-page);
  }
  .burger {
    position: fixed;
    top: 18px;
    left: 20px;
    z-index: 40;
  }
  .burger-btn {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 0;
  }
  .burger-btn:hover {
    color: var(--text-primary);
  }
  .main {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }
  .scroll {
    flex: 1;
    overflow-y: auto;
    min-width: 0;
  }
  .column {
    max-width: 1180px;
    margin: 0 auto;
    width: 100%;
    box-sizing: border-box;
    padding: 0 32px 40px 96px;
    display: flex;
    flex-direction: column;
  }
  .topbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 18px 0 20px;
    position: relative;
  }
  .back {
    position: absolute;
    left: -40px;
    top: 50%;
    transform: translateY(-50%);
  }
  .title {
    cursor: pointer;
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 20px;
    color: var(--text-primary);
  }
  .title.static {
    cursor: default;
  }
  .count {
    font-size: 14px;
    color: var(--text-tertiary);
    font-weight: 400;
  }
  .spacer {
    flex: 1;
  }
  .topbar-actions {
    display: flex;
    align-items: center;
    gap: 2px;
    margin-right: -6px;
  }
  .cmdk {
    border: 1px solid var(--border-default);
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    border-radius: var(--radius-pill);
    padding: 5px 10px;
    display: flex;
    align-items: center;
    gap: 6px;
    font-family: var(--font-mono);
    font-size: 11.5px;
    margin-right: 6px;
  }
  .cmdk:hover {
    color: var(--text-primary);
  }
  .empty {
    padding: 40px 0;
    text-align: center;
    color: var(--text-tertiary);
    font-family: var(--font-body);
    font-size: 14px;
  }
  .compose-fs {
    position: fixed;
    inset: 0;
    z-index: 80;
    background: var(--surface-card);
    display: flex;
    flex-direction: column;
  }
  .compose-fs-head {
    max-width: 1180px;
    margin: 0 auto;
    width: 100%;
    box-sizing: border-box;
    padding: 18px 32px 0;
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }
  .compose-fs-title {
    flex: 1;
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 20px;
    color: var(--text-primary);
  }
  .compose-fs-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 0 0 40px;
  }
  .compose-fs-column {
    max-width: 1180px;
    margin: 0 auto;
    width: 100%;
    box-sizing: border-box;
    padding: 20px 32px 0;
    display: flex;
    flex-direction: column;
    min-height: 100%;
  }
  .compose-backdrop {
    position: fixed;
    inset: 0;
    z-index: 80;
    background: rgba(17, 19, 24, 0.32);
    backdrop-filter: blur(6px);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 40px;
  }
  .compose-modal {
    background: var(--surface-card);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    width: 720px;
    max-width: 100%;
    height: min(680px, 88vh);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .compose-head {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 16px 24px;
    flex-shrink: 0;
  }
  .compose-title {
    flex: 1;
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 16px;
    color: var(--text-primary);
  }
  .compose-body {
    flex: 1;
    overflow-y: auto;
    padding: 0 24px;
    display: flex;
    flex-direction: column;
    min-height: 0;
  }
  .compose-body-inner {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-height: 100%;
  }
</style>
