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
  import Toast from "./lib/ds/Toast.svelte";
  import { ACCOUNTS, EMAILS_SEED, FOLDER_TITLES, LABELS, type Account, type Email, type LabelDef, type ThreadMsg } from "./lib/data";
  import type { ComposeData } from "./lib/Composer.svelte";
  import { toasts, toast, dismissToast } from "./lib/toast.svelte";
  import * as ipc from "./lib/ipc";

  let sidebarOpen = $state(false);
  let sidebarWidth = $state(Number(localStorage.getItem("sidebarWidth")) || 248);
  function resizeSidebar(w: number) {
    sidebarWidth = w;
    localStorage.setItem("sidebarWidth", String(w));
  }
  // Frontend-only sidebar prefs (persisted like sidebarWidth): hidden
  // folder/label keys + per-label color overrides.
  function readJson<T>(key: string, fallback: T): T {
    try {
      return JSON.parse(localStorage.getItem(key) ?? "") as T;
    } catch {
      return fallback;
    }
  }
  let hiddenSidebar: string[] = $state(readJson("sidebarHidden", []));
  let labelColors: Record<string, string> = $state(readJson("sidebarLabelColors", {}));
  function hideSidebarItem(key: string) {
    if (!hiddenSidebar.includes(key)) {
      hiddenSidebar = [...hiddenSidebar, key];
      localStorage.setItem("sidebarHidden", JSON.stringify(hiddenSidebar));
    }
    // Hiding the active view must not leave it open behind a hidden entry.
    if (folder === key) selectFolder("inbox");
  }
  function unhideSidebarItem(key: string) {
    hiddenSidebar = hiddenSidebar.filter((k) => k !== key);
    localStorage.setItem("sidebarHidden", JSON.stringify(hiddenSidebar));
  }
  function setLabelColor(key: string, tag: string) {
    labelColors = { ...labelColors, [key]: tag };
    localStorage.setItem("sidebarLabelColors", JSON.stringify(labelColors));
  }
  // Gmail label management (context menu). Optimistic sidebar update, then
  // reconcile from listLabels once the backend confirms (or on failure).
  function reconcileLabels() {
    ipc
      .listLabels()
      .then((ls) => (liveLabels = ls))
      .catch(() => {});
  }
  function renameLabel(key: string, newName: string) {
    if (!ipc.isTauri || !liveAccounts.length) {
      toast("info", "Connect Gmail to manage labels");
      return;
    }
    const id = key.replace(/^label:/, "");
    liveLabels = liveLabels.map((l) => (l.id === id ? { ...l, name: newName } : l));
    ipc
      .updateLabel(id, newName)
      .then(() => {
        reconcileLabels();
        toast("success", "Label renamed", newName);
      })
      .catch((e) => {
        console.error("rename label failed", e);
        toast("danger", "Could not rename label", String(e));
        reconcileLabels();
      });
  }
  function deleteLabel(key: string) {
    if (!ipc.isTauri || !liveAccounts.length) {
      toast("info", "Connect Gmail to manage labels");
      return;
    }
    const id = key.replace(/^label:/, "");
    const name = liveLabels.find((l) => l.id === id)?.name;
    liveLabels = liveLabels.filter((l) => l.id !== id);
    if (folder === key) selectFolder("inbox");
    ipc
      .deleteLabel(id)
      .then(() => {
        reconcileLabels();
        toast("success", "Label deleted", name);
      })
      .catch((e) => {
        console.error("delete label failed", e);
        toast("danger", "Could not delete label", String(e));
        reconcileLabels();
      });
  }
  let view: "mail" | "calendar" = $state("mail");
  let unified = $state(true);
  let activeAccountId = $state("a1");
  let folder = $state("inbox");
  let selectedId: string | null = $state(null);
  // Keyboard cursor: arrows/j/k move this highlight without opening the
  // preview card; Enter opens the thread.
  let cursorId: string | null = $state(null);
  let threadOpen = $state(false);
  let scrollEl: HTMLDivElement | undefined = $state();
  let composeOpen = $state(false);
  // Restored draft after a send-undo; non-null reopens the composer prefilled.
  let composeDraft: ComposeData | null = $state(null);
  let searchOpen = $state(false);
  let paletteOpen = $state(false);
  let fullscreen = $state(false);
  let composeFullscreen = $state(false);
  let emailsData: Email[] = $state(EMAILS_SEED);
  let hoverActions: string[] = $state(["delete", "pin", "remind"]);
  let pinListEnabled = $state(true);
  let liveAccounts: Account[] = $state([]);
  let liveLabels: ipc.BackendLabel[] = $state([]);

  // Folder key → backend list_threads filter. `label:<id>` passes through;
  // scheduled/settings (and the mock label-* keys) have no backend folder.
  const FOLDER_FILTERS: Record<string, ipc.ThreadFilter> = {
    inbox: "inbox",
    all: "all",
    starred: "starred",
    sent: "sent",
    drafts: "drafts",
    archive: "archive",
    spam: "spam",
    trash: "trash",
  };
  function filterFor(f: string): ipc.ThreadFilter | null {
    if (f.startsWith("label:")) return f as ipc.ThreadFilter;
    return FOLDER_FILTERS[f] ?? null;
  }
  // Last fetched rows per folder — shown instantly on folder switch while
  // the refetch runs.
  const folderCache = new Map<string, Email[]>();

  // Ids of threads currently in the inbox (from the dedicated inbox fetch).
  // `push` collapses multi-folder membership into one display key (a starred
  // inbox thread renders under "starred" while that view is open), so the
  // sidebar inbox badge must track membership separately or it drops to 0
  // whenever another folder view is active.
  let inboxIds = $state<Set<string>>(new Set());

  // Live mode: inside Tauri the mock seed is replaced by real store data.
  async function refreshLive() {
    const f = folder;
    const filter = filterFor(f);
    const wantFolder = filter !== null && filter !== "inbox";
    const [accounts, threads, folderThreads, scheduled, labels] = await Promise.all([
      ipc.listAccounts(),
      ipc.listThreads(),
      wantFolder ? ipc.listThreads(filter!) : Promise.resolve([] as ipc.BackendThread[]),
      ipc.listScheduled(),
      ipc.listLabels(),
    ]);
    liveAccounts = accounts.map((a) => ({
      id: a.id,
      email: a.email,
      label: a.display_name,
      tag: a.color,
      avatarUrl: a.avatar_url ?? undefined,
      signature: a.signature,
    }));
    liveLabels = labels;
    inboxIds = new Set(threads.map((t) => t.id));
    // Preserve already-loaded bodies + local flags across refreshes.
    const prev = new Map(emailsData.map((e) => [e.id, e]));
    const seen = new Set<string>();
    const rows: Email[] = [];
    const push = (t: ipc.BackendThread, folderKey: string) => {
      if (seen.has(t.id) || pendingUndo.has(t.id)) return;
      seen.add(t.id);
      const mapped = ipc.threadToEmail(t);
      mapped.folder = folderKey;
      const old = prev.get(t.id);
      rows.push(old?.thread ? { ...mapped, thread: old.thread } : mapped);
    };
    // Active-folder rows first: a thread living in several folders at once
    // (inbox + starred, say) must render in the open view.
    for (const t of folderThreads) push(t, f);
    for (const t of threads) push(t, "inbox");
    // Scheduled threads that left the inbox window (archived, or beyond the
    // list_threads page limit) must still feed the calendar view. Ones no
    // longer in the inbox must not leak into the inbox folder view.
    for (const t of scheduled) {
      if (!seen.has(t.id)) push(t, !t.is_inbox || t.is_archived ? "archive" : "inbox");
    }
    emailsData = rows;
    folderCache.set(f, rows.filter((e) => f === "all" || e.folder === f));
    // Search hits merged from outside the inbox (archived etc.) are not in
    // list_threads; while one is selected/open, dropping it would blank the
    // open ThreadView (mark_read fires threads_updated right after opening).
    if (selectedId && !emailsData.some((e) => e.id === selectedId)) {
      const kept = prev.get(selectedId);
      if (kept) emailsData = [...emailsData, kept];
    }
    if (liveAccounts.length && !liveAccounts.some((a) => a.id === activeAccountId)) {
      activeAccountId = liveAccounts[0].id;
    }
  }

  $effect(() => {
    if (!ipc.isTauri) return;
    let unsub: (() => void) | undefined;
    ipc.onThreadsUpdated(() => {
      refreshLive().catch((e) => {
        console.error("ipc refresh failed", e);
        toast("danger", "Refresh failed", String(e));
      });
    }).then((u) => (unsub = u));
    return () => unsub?.();
  });

  // Initial load + per-folder refetch: folder views come from the backend
  // (list_threads filter), not from client-side filtering of the inbox page.
  $effect(() => {
    if (!ipc.isTauri) return;
    void folder;
    refreshLive().catch((e) => {
      console.error("ipc refresh failed", e);
      toast("danger", "Refresh failed", String(e));
    });
  });

  const accounts = $derived(ipc.isTauri && liveAccounts.length ? liveAccounts : ACCOUNTS);



  // Real user labels in live mode (name-sorted by the backend; tag palette
  // cycles); design mocks in browser mode. CATEGORY_* never reaches here
  // (the adapter stores user-type labels only) but guard anyway.
  const LABEL_TAGS = ["amber", "coral", "mint", "sky", "lavender"];
  const sidebarLabels = $derived.by((): LabelDef[] => {
    // Color overrides (context menu pref) beat the cyclic palette — in both
    // mock and live mode, everywhere sidebarLabels feeds.
    if (!ipc.isTauri || !liveAccounts.length)
      return LABELS.map((l) => ({ ...l, tag: labelColors[l.key] ?? l.tag }));
    // Dedupe by label id: the same Gmail label id can exist in BOTH accounts
    // (e.g. Label_36), and duplicate {#each} keys crash the whole render
    // (each_key_duplicate — this froze the app on mock data once).
    const byId = new Map<string, ipc.BackendLabel>();
    for (const l of liveLabels) {
      if (!l.id.startsWith("CATEGORY_") && !byId.has(l.id)) byId.set(l.id, l);
    }
    return [...byId.values()].map((l, i) => ({
      key: `label:${l.id}`,
      label: l.name,
      tag: labelColors[`label:${l.id}`] ?? LABEL_TAGS[i % LABEL_TAGS.length],
    }));
  });

  const emails = $derived.by(() => {
    // Calendar view: only scheduled mail, ascending by schedule (matches the
    // grouped render order so j/k navigation follows the visual order).
    const base =
      view === "calendar"
        ? emailsData
            .filter((e) => e.scheduledAt !== undefined)
            .sort((a, b) => (a.scheduledAt ?? 0) - (b.scheduledAt ?? 0))
        : emailsData.filter((e) => (folder === "all" ? true : e.folder === folder));
    return base
      .filter((e) => unified || e.accountId === activeAccountId)
      .map((e) =>
        unified ? { ...e, accountTag: accounts.find((a) => a.id === e.accountId)?.tag } : e,
      );
  });
  const email = $derived(
    emails.find((e) => e.id === selectedId) ?? emailsData.find((e) => e.id === selectedId),
  );
  const counts = $derived({
    inbox: emailsData.filter(
      (e) =>
        (e.folder === "inbox" || inboxIds.has(e.id)) &&
        e.unread &&
        (unified || e.accountId === activeAccountId),
    ).length,
  });
  const title = $derived.by(() =>
    view === "calendar"
      ? "Scheduled"
      : unified && folder === "inbox"
        ? "All inboxes"
        : (FOLDER_TITLES[folder] ??
          sidebarLabels.find((l) => l.key === folder)?.label ??
          folder),
  );
  // Compose defaults to the viewed account filter; unified view falls back to the first account.
  const composeFromId = $derived(unified ? accounts[0]?.id : activeAccountId);
  const signatureFor = (accountId: string) => accounts.find((a) => a.id === accountId)?.signature;

  // Deferred-commit undo window: destructive/irreversible actions apply
  // optimistically in the UI but the backend mutation only fires after this
  // delay, so the toast's Undo can cancel it without any backend call.
  // ponytail: quitting the app inside the undo window silently drops the
  // pending action (the mutation never reaches the backend) — accepted.
  const UNDO_MS = 5000;
  // Thread ids with a pending deferred archive/trash. refreshLive must not
  // re-add these rows (the backend hasn't mutated yet) or they would flicker
  // back in during routine sync inside the undo window.
  const pendingUndo = new Set<string>();

  function onEmailAction(id: string, action: string) {
    const em = emailsData.find((e) => e.id === id);
    // ponytail: un-trash/un-spam needs new Mutation kinds (add INBOX, remove
    // TRASH/SPAM); until then archive ('e') is disabled in Trash and Spam —
    // remove-INBOX would be a nonsensical no-op on already-trashed mail.
    if (ipc.isTauri && action === "done" && (folder === "trash" || folder === "spam")) return;
    if (em && (action === "done" || action === "delete")) {
      // Optimistic: drop from the local list now; the backend mutation is
      // deferred so Undo can cancel it and reinsert the row in place.
      const index = emailsData.indexOf(em);
      emailsData = emailsData.filter((e) => e.id !== id);
      if (selectedId === id) selectedId = null;
      pendingUndo.add(id);
      let fired = false;
      const timer = setTimeout(() => {
        fired = true;
        pendingUndo.delete(id);
        if (!ipc.isTauri) return;
        const mutation =
          action === "done"
            ? ({ kind: "archive", thread_id: id } as const)
            : ({ kind: "trash", thread_id: id } as const);
        ipc.mutate(em.accountId, mutation).catch((e) => {
          console.error("mutate failed", e);
          toast("danger", action === "done" ? "Could not archive" : "Could not delete", String(e));
        });
      }, UNDO_MS);
      toast("success", action === "done" ? "Archived" : "Deleted", em.subject, {
        actionLabel: "Undo",
        duration: UNDO_MS,
        onAction: () => {
          // The mutate timer and toast auto-dismiss share the same deadline;
          // never undo an action that already committed.
          if (fired) return;
          clearTimeout(timer);
          pendingUndo.delete(id);
          // A refresh may have re-added the row already (backend never mutated).
          if (emailsData.some((e) => e.id === id)) return;
          const i = Math.min(index, emailsData.length);
          emailsData = [...emailsData.slice(0, i), em, ...emailsData.slice(i)];
        },
      });
      return;
    }
    if (em && action === "unread") {
      // Trivially reversible — immediate mutate, no undo deferral.
      const read = em.unread;
      emailsData = emailsData.map((e) => (e.id === id ? { ...e, unread: !e.unread } : e));
      if (ipc.isTauri) {
        ipc.mutate(em.accountId, { kind: "mark_read", thread_id: id, read }).catch((e) => {
          console.error("mutate failed", e);
          toast("danger", "Could not update read state", String(e));
        });
      }
      return;
    }
    if (action === "pin") emailsData = emailsData.map((e) => (e.id === id ? { ...e, pinned: !e.pinned } : e));
    else console.log(id, action);
  }

  // Local-only "remind me" schedule (never synced to Gmail). Optimistic; the
  // backend confirms via threads_updated → refreshLive.
  function setSchedule(id: string, scheduledAt: number | null) {
    const em = emailsData.find((e) => e.id === id);
    if (!em) return;
    const previous = em.scheduledAt;
    emailsData = emailsData.map((e) =>
      e.id === id ? { ...e, scheduledAt: scheduledAt ?? undefined } : e,
    );
    const confirm = () =>
      scheduledAt !== null
        ? toast("success", `Scheduled for ${ipc.fmtFull(scheduledAt)}`, em.subject)
        : toast("success", "Schedule removed", em.subject);
    if (!ipc.isTauri) {
      confirm();
      return;
    }
    ipc
      .setSchedule(em.accountId, id, scheduledAt)
      .then(confirm)
      .catch((e) => {
        console.error("set_schedule failed", e);
        toast("danger", "Could not schedule", String(e));
        emailsData = emailsData.map((x) => (x.id === id ? { ...x, scheduledAt: previous } : x));
      });
  }

  function switchView(v: "mail" | "calendar") {
    if (view === v) return;
    view = v;
    selectedId = null;
    threadOpen = false;
    fullscreen = false;
  }

  function sendCompose(data: ComposeData) {
    // Pre-send validation runs BEFORE the undo deferral. Before refreshLive
    // resolves, `accounts` is mock data — a send routed to a mock account id
    // would sit in the outbox failing forever.
    if (ipc.isTauri && !liveAccounts.some((a) => a.id === data.accountId)) {
      console.error("compose account not connected", data.accountId);
      toast("danger", "Could not send", "Account is not connected yet");
      return;
    }
    const n = data.to.length + data.cc.length + data.bcc.length;
    const desc = n === 1 ? `To ${data.to[0] ?? data.cc[0] ?? data.bcc[0]}` : `To ${n} recipients`;
    let fired = false;
    const timer = setTimeout(() => {
      fired = true;
      if (!ipc.isTauri) {
        toast("success", "Message sent", desc);
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
        .then(() => toast("success", "Message sent", desc))
        .catch((e) => {
          console.error("send failed", e);
          toast("danger", "Could not send", String(e));
        });
    }, UNDO_MS);
    toast("info", "Sending…", desc, {
      actionLabel: "Undo",
      duration: UNDO_MS,
      onAction: () => {
        // A committed send must not reopen the composer (duplicate-send bait).
        if (fired) return;
        clearTimeout(timer);
        // Reopen the composer prefilled with the cancelled draft.
        composeDraft = { ...data };
        composeOpen = true;
      },
    });
  }

  function sendReply(em: Email, msg: ThreadMsg, body: string) {
    // Pre-send validation runs BEFORE the undo deferral. Reply goes to the
    // sender of the replied-to message; replying to your own message targets
    // the other participant.
    const to = msg.isMe
      ? (em.thread?.findLast((m) => !m.isMe)?.fromAddr ?? "")
      : (msg.fromAddr ?? "");
    if (ipc.isTauri && !to) {
      console.error("no reply address available");
      toast("danger", "Could not reply", "No reply address available");
      return;
    }
    const subject = /^re:/i.test(em.subject) ? em.subject : `Re: ${em.subject}`;
    let fired = false;
    const timer = setTimeout(() => {
      fired = true;
      if (!ipc.isTauri) {
        toast("success", "Reply sent", to ? `To ${to}` : em.from);
        return;
      }
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
        .then(() => toast("success", "Reply sent", `To ${to}`))
        .catch((e) => {
          console.error("send failed", e);
          toast("danger", "Could not send reply", String(e));
        });
    }, UNDO_MS);
    toast("info", "Sending…", subject, {
      actionLabel: "Undo",
      duration: UNDO_MS,
      onAction: () => {
        if (fired) return;
        clearTimeout(timer);
        // ponytail: restoring the reply text into the inline reply box would
        // require plumbing draft state through ThreadView/InboxList/InlineReply;
        // best-effort fallback for reply only — copy the body to the clipboard.
        // The clipboard is the only surviving copy — only claim success once
        // the write resolved; otherwise be honest that the text is gone.
        const copyFailed = () =>
          toast("danger", "Reply cancelled", "Could not copy your reply text to the clipboard");
        if (navigator.clipboard) {
          navigator.clipboard
            .writeText(body)
            .then(() => toast("info", "Reply cancelled", "Your reply text was copied to the clipboard"))
            .catch(copyFailed);
        } else {
          copyFailed();
        }
      },
    });
  }

  function updateAccount(id: string, fields: { displayName?: string; color?: string; signature?: string }) {
    if (!ipc.isTauri) return;
    ipc.updateAccount(id, fields).catch((e) => {
      console.error("update account failed", e);
      toast("danger", "Could not update account", String(e));
    });
  }

  function removeAccount(id: string) {
    if (!ipc.isTauri) return;
    ipc.removeAccount(id).catch((e) => {
      console.error("remove failed", e);
      toast("danger", "Could not remove account", String(e));
    });
  }

  async function addAccount() {
    if (!ipc.isTauri) return;
    try {
      const email = await ipc.startGmailOauth();
      console.info("connected", email);
      await refreshLive();
      toast("success", "Account connected", email);
    } catch (e) {
      // alert() is a no-op in WKWebView — surface in-UI.
      toast("danger", "Could not connect account", String(e));
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
    // Fresh read starts at the top, not wherever the list was scrolled.
    requestAnimationFrame(() => scrollEl?.scrollTo({ top: 0 }));
  }

  function selectFolder(f: string) {
    // Instant switch: surface the last fetched rows for this folder now; the
    // folder-tracking $effect refetches right after.
    if (ipc.isTauri && f !== folder) {
      const cached = folderCache.get(f)?.filter((e) => !pendingUndo.has(e.id));
      if (cached?.length) {
        const ids = new Set(cached.map((e) => e.id));
        emailsData = [...cached, ...emailsData.filter((e) => !ids.has(e.id))];
      }
    }
    folder = f;
    view = "mail";
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
    composeDraft = null;
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
    // The search overlay owns the keyboard, but Escape must close it even
    // when focus has left its input (e.g. after clicking overlay whitespace).
    if (searchOpen) {
      if (ev.key === "Escape") {
        ev.preventDefault();
        searchOpen = false;
      }
      return;
    }
    // List navigation — never while typing or while an overlay owns the keyboard.
    if (isEditable(ev.target) || paletteOpen || composeOpen) return;
    if (ev.key === "/") {
      ev.preventDefault();
      searchOpen = true;
      return;
    }
    if (ev.key === "Escape") {
      if (threadOpen) {
        threadOpen = false;
        fullscreen = false;
      } else if (selectedId !== null) {
        selectedId = null;
      } else if (cursorId !== null) {
        cursorId = null;
      }
      return;
    }
    if (threadOpen || (view === "mail" && folder === "settings")) return;
    const actId = cursorId ?? selectedId;
    if (ev.key === "e" && actId !== null) {
      ev.preventDefault();
      if (cursorId === actId) cursorId = null;
      onEmailAction(actId, "done");
      return;
    }
    if (ev.key === "#" && actId !== null) {
      ev.preventDefault();
      if (cursorId === actId) cursorId = null;
      onEmailAction(actId, "delete");
      return;
    }
    if (ev.key === "u" && actId !== null) {
      ev.preventDefault();
      onEmailAction(actId, "unread");
      return;
    }
    if (ev.key === "j" || ev.key === "ArrowDown") {
      ev.preventDefault();
      const i = emails.findIndex((e) => e.id === (cursorId ?? selectedId));
      const next = emails[Math.min(i + 1, emails.length - 1)];
      selectedId = null; // cursor-only: no preview card while navigating
      if (next) cursorId = next.id;
    } else if (ev.key === "k" || ev.key === "ArrowUp") {
      ev.preventDefault();
      const i = emails.findIndex((e) => e.id === (cursorId ?? selectedId));
      const prev = emails[Math.max(i - 1, 0)];
      selectedId = null;
      if (prev) cursorId = prev.id;
    } else if (ev.key === "Enter" && (cursorId !== null || selectedId !== null)) {
      ev.preventDefault();
      openThread((cursorId ?? selectedId)!);
    }
  }
</script>

<svelte:document onkeydown={onKey} />

<div class="frame">
  <header class="apphead" data-tauri-drag-region>
    <span class="apphead-title" data-tauri-drag-region>
      {title}
      {#if !threadOpen && (view === "calendar" || folder !== "settings")}
        <span class="apphead-count">{emails.length}</span>
      {/if}
    </span>
  </header>
  <div class="app">
  <Sidebar
    open={sidebarOpen}
    width={sidebarWidth}
    onResize={resizeSidebar}
    active={folder}
    onSelect={selectFolder}
    {accounts}
    {activeAccountId}
    {unified}
    onSelectAccount={(id) => (activeAccountId = id)}
    onToggleUnified={(v) => (unified = v)}
    onAddAccount={addAccount}
    {counts}
    labels={sidebarLabels}
    hidden={hiddenSidebar}
    onHide={hideSidebarItem}
    onUnhide={unhideSidebarItem}
    onSetColor={setLabelColor}
    onRenameLabel={renameLabel}
    onDeleteLabel={deleteLabel}
  />
  <div class="rail">
    <button
      class="rail-btn"
      title={sidebarOpen ? "Close sidebar" : "Open sidebar"}
      onclick={() => (sidebarOpen = !sidebarOpen)}
    >
      {#if sidebarOpen}
        <Icon d="M6 6l12 12M18 6L6 18" size={17} />
      {:else}
        <Icon d="M4 7h16M4 12h16M4 17h16" size={17} />
      {/if}
    </button>
    <div class="rail-views">
      <button
        class="rail-btn"
        class:active={view === "mail"}
        title="Inbox"
        onclick={() => switchView("mail")}
      >
        <Icon
          d="M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z"
          size={17}
          fill={view === "mail" ? "currentColor" : "none"}
        />
      </button>
      <button
        class="rail-btn"
        class:active={view === "calendar"}
        title="Scheduled"
        onclick={() => switchView("calendar")}
      >
        <Icon
          d="M8 3v3M16 3v3M4 9h17M6 5h12a2 2 0 012 2v12a2 2 0 01-2 2H6a2 2 0 01-2-2V7a2 2 0 012-2z"
          size={17}
        />
      </button>
    </div>
    <button
      class="rail-btn rail-settings"
      class:active={view === "mail" && folder === "settings"}
      title="Settings"
      onclick={() => {
        if (view !== "mail") switchView("mail");
        selectFolder("settings");
      }}
    >
      <Icon
        d="M12 15a3 3 0 100-6 3 3 0 000 6z M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09a1.65 1.65 0 00-1-1.51 1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 110-4h.09a1.65 1.65 0 001.51-1 1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06a1.65 1.65 0 001.82.33h0A1.65 1.65 0 0010 3.09V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82v0c.27.6.85 1 1.51 1H21a2 2 0 110 4h-.09a1.65 1.65 0 00-1.51 1z"
        size={16}
      />
    </button>
  </div>

  <div class="main">
    <div class="scroll" bind:this={scrollEl}>
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
            <div class="spacer"></div>
            {#if !threadOpen && (view === "calendar" || folder !== "settings")}
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
        {#if view === "mail" && folder === "settings"}
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
            {cursorId}
            mode={view === "calendar" ? "scheduled" : "inbox"}
            onSelect={selectEmail}
            onOpen={openThread}
            onAction={onEmailAction}
            onSchedule={setSchedule}
            onSendReply={(em, body) => {
              const target = em.thread?.[em.thread.length - 1];
              if (target) sendReply(em, target, body);
            }}
            signatureFor={(em) => signatureFor(em.accountId)}
            {hoverActions}
            {pinListEnabled}
          />
          {#if emails.length === 0}
            <div class="empty">{view === "calendar" ? "Nothing scheduled" : "Nothing here yet"}</div>
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
            {#key composeDraft}
              <Composer onClose={closeCompose} onSend={sendCompose} {accounts} initialAccountId={composeFromId} initialDraft={composeDraft ?? undefined} />
            {/key}
          </div>
        </div>
      </div>
    {:else}
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <div
        class="compose-backdrop"
        onmousedown={(ev) => {
          if (ev.target === ev.currentTarget) closeCompose();
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
              {#key composeDraft}
                <Composer onClose={closeCompose} onSend={sendCompose} {accounts} initialAccountId={composeFromId} initialDraft={composeDraft ?? undefined} />
              {/key}
            </div>
          </div>
        </div>
      </div>
    {/if}
  {/if}

  {#if toasts.length}
    <div class="toast-stack">
      {#each toasts as t (t.id)}
        <Toast
          tone={t.tone}
          title={t.title}
          description={t.description}
          actionLabel={t.actionLabel}
          onAction={t.onAction}
          onClose={() => dismissToast(t.id)}
        />
      {/each}
    </div>
  {/if}
  </div>
</div>

<style>
  .app {
    flex: 1;
    min-height: 0;
    display: flex;
    font-family: var(--font-body);
    background: var(--bg-page);
    overflow-x: hidden;
  }
  .rail {
    width: 52px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    /* One shade darker than the sidebar panel (navy-50) so the two surfaces
       read as separate layers. */
    background: var(--navy-100);
    padding-top: 14px;
    gap: 4px;
    z-index: 40;
  }
  .rail-btn {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    border-radius: var(--radius-md);
    padding: 0;
  }
  .rail-btn:hover {
    color: var(--text-primary);
  }
  .rail-btn.active {
    color: var(--text-primary);
    background: var(--surface-card);
    border: 1px solid var(--border-subtle);
    box-shadow: var(--shadow-xs);
  }
  .rail-settings {
    margin-top: auto;
    margin-bottom: 14px;
  }
  .rail-views {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-top: 12px;
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
    overflow-x: hidden;
    min-width: 0;
  }
  .column {
    max-width: 1420px;
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
    padding: 12px 0 16px;
    position: relative;
  }
  .back {
    position: absolute;
    left: -40px;
    top: 50%;
    transform: translateY(-50%);
  }
  .frame {
    height: 100%;
    display: flex;
    flex-direction: column;
  }
  .apphead {
    height: 48px;
    flex-shrink: 0;
    background: var(--surface-card);
    border-bottom: 1px solid var(--border-subtle);
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .apphead-title {
    font-family: var(--font-display);
    font-weight: 700;
    font-size: 15px;
    color: var(--text-primary);
  }
  .apphead-count {
    font-size: 13px;
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
    max-width: 1420px;
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
    max-width: 1420px;
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
  .toast-stack {
    position: fixed;
    right: 20px;
    bottom: 20px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    z-index: 200;
  }
</style>
