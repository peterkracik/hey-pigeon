<script lang="ts">
  import Sidebar from "./lib/Sidebar.svelte";
  import InboxList from "./lib/InboxList.svelte";
  import ThreadView from "./lib/ThreadView.svelte";
  import Composer from "./lib/Composer.svelte";
  import SearchOverlay from "./lib/SearchOverlay.svelte";
  import CommandPalette from "./lib/CommandPalette.svelte";
  import Settings from "./lib/Settings.svelte";
  import TriageFilter from "./lib/TriageFilter.svelte";
  import IconButton from "./lib/ds/IconButton.svelte";
  import Tooltip from "./lib/ds/Tooltip.svelte";
  import Icon from "./lib/ds/Icon.svelte";
  import Toast from "./lib/ds/Toast.svelte";
  import SegmentedControl from "./lib/ds/SegmentedControl.svelte";
  import { ACCOUNTS, EMAILS_SEED, FOLDER_TITLES, LABELS, type Account, type Email, type LabelDef, type ThreadMsg } from "./lib/data";
  import type { ComposeData } from "./lib/Composer.svelte";
  import type { ReplySendData } from "./lib/InlineReply.svelte";
  import { toasts, toast, dismissToast } from "./lib/toast.svelte";
  import * as ipc from "./lib/ipc";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { isPermissionGranted, requestPermission, sendNotification } from "@tauri-apps/plugin-notification";

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
  // Schedule view filter: everything, or hide completed reminders (the
  // still-outstanding ones are what matter — isolating only-done made no
  // sense as the switcher's second option).
  let schedFilter: "all" | "active" = $state(readJson("schedFilter", "all"));
  function setSchedFilter(v: string) {
    schedFilter = v as "all" | "active";
    localStorage.setItem("schedFilter", JSON.stringify(schedFilter));
  }
  // Inbox/folder view filter: everything, or only unread.
  let inboxFilter: "all" | "unread" = $state(readJson("inboxFilter", "all"));
  function setInboxFilter(v: string) {
    inboxFilter = v as "all" | "unread";
    localStorage.setItem("inboxFilter", JSON.stringify(inboxFilter));
  }
  // Filters & sorting row — collapsed by default, revealed below the
  // All/Unread (or All/Hide done) segmented control via its own toggle.
  let sortFilterOpen = $state(false);
  let emailSortOrder: "newest" | "oldest" | "unread" = $state(readJson("emailSortOrder", "newest"));
  function setEmailSortOrder(v: string) {
    emailSortOrder = v as "newest" | "oldest" | "unread";
    localStorage.setItem("emailSortOrder", JSON.stringify(emailSortOrder));
  }
  let attachmentOnly = $state(readJson("attachmentOnly", false));
  function setAttachmentOnly(v: boolean) {
    attachmentOnly = v;
    localStorage.setItem("attachmentOnly", JSON.stringify(attachmentOnly));
  }
  // Received-date filter — mail view only (live mode has lastMsgAt; mock
  // seed data doesn't, so undated rows always pass rather than vanishing
  // in browser dev mode). Calendar view already buckets by due date
  // (Today/Tomorrow/This week/Later), so it doesn't get a second one.
  let dateFilter: "all" | "today" | "week" | "month" = $state(readJson("dateFilter", "all"));
  function setDateFilter(v: string) {
    dateFilter = v as "all" | "today" | "week" | "month";
    localStorage.setItem("dateFilter", JSON.stringify(dateFilter));
  }
  // All three persist across relaunch (unlike activeTriageFilter) — this
  // keeps the toggle button visibly "on" even while the row is collapsed,
  // so a stale filter can't silently hide mail unnoticed.
  const hasNonDefaultSortFilter = $derived(attachmentOnly || emailSortOrder !== "newest" || dateFilter !== "all");
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
  let view: "mail" | "calendar" | "search" = $state("mail");
  // Search is a real view, not an overlay bolted on top — it fully replaces
  // the mail/calendar content (no risk of it silently sitting on top of a
  // folder switch that happened underneath). Remember which one to return to.
  let searchReturn: "mail" | "calendar" = "mail";
  function openSearch() {
    if (view !== "search") searchReturn = view;
    view = "search";
  }
  function closeSearch() {
    if (view === "search") view = searchReturn;
  }
  // Quick filter: fuzzy-narrows the CURRENTLY LOADED rows in place (client
  // side, no backend round trip) — distinct from the rail's Search view,
  // which queries every message. '/' triggers this, not global search.
  let quickFilterOpen = $state(false);
  let quickFilter = $state("");
  function openQuickFilter() {
    quickFilterOpen = true;
  }
  function closeQuickFilter() {
    quickFilterOpen = false;
    quickFilter = "";
  }
  let unified = $state(true);
  let activeAccountId = $state("a1");
  let folder = $state("inbox");
  let selectedId: string | null = $state(null);
  // Keyboard cursor: arrows/j/k move this highlight without opening the
  // preview card; Enter opens the thread.
  let cursorId: string | null = $state(null);
  // Multi-select checkboxes (Gmail-style bulk actions) — disjoint from the
  // single-row preview/cursor above.
  let selectedIds: Set<string> = $state(new Set());
  let threadOpen = $state(false);
  let scrollEl: HTMLDivElement | undefined = $state();
  let composeOpen = $state(false);
  let settingsOpen = $state(false);
  // Restored draft after a send-undo; non-null reopens the composer prefilled.
  let composeDraft: ComposeData | null = $state(null);
  let paletteOpen = $state(false);
  // Two-stage palette (label / move pickers): stage 2 rows + the pending
  // target/mode. Esc or the back button returns to stage 1.
  type PaletteStage = { title: string; items: { key: string; label: string; d: string }[] };
  let paletteStage: PaletteStage | null = $state(null);
  let paletteStageCtx: { mode: "label" | "move"; targetId: string } | null = $state(null);
  // Imperative hook into InboxList's remind popover (palette / 'h').
  let remindRequestId: string | null = $state(null);
  // ThreadView starts with the inline reply open (palette Reply / 'r').
  // Monotonic request counter, not a boolean: each bump is consumed once by
  // ThreadView, so repeat Reply on the open thread works and sync refreshes
  // can't resurrect a cancelled reply box.
  let threadReplyStart = $state(0);
  let fullscreen = $state(false);
  let composeFullscreen = $state(false);
  let emailsData: Email[] = $state(EMAILS_SEED);
  let hoverActions: string[] = $state(readJson("hoverActions", ["delete", "pin", "remind"]));
  function setHoverActions(next: string[]) {
    hoverActions = next;
    localStorage.setItem("hoverActions", JSON.stringify(hoverActions));
  }
  let pinListEnabled = $state(readJson("pinListEnabled", true));
  function setPinListEnabled(v: boolean) {
    pinListEnabled = v;
    localStorage.setItem("pinListEnabled", JSON.stringify(pinListEnabled));
  }
  // Opt-in: generate AI summaries (inbox groups + open thread) as soon as
  // they're viewable instead of waiting for an explicit "Summarize" click.
  // Off by default \u2014 same explicit-action privacy posture as everywhere
  // else in the AI section until the user turns this on themselves.
  let autoSummarize = $state(readJson("autoSummarize", false));
  function setAutoSummarize(v: boolean) {
    autoSummarize = v;
    localStorage.setItem("autoSummarize", JSON.stringify(autoSummarize));
  }
  let liveAccounts: Account[] = $state([]);
  // Lazy loading: rows come in pages of 50; scrolling near the bottom raises
  // the limit and refetches (keyset-paginated locally — milliseconds).
  const PAGE = 50;
  let listLimit = $state(PAGE);
  let hasMoreRows = $state(true);
  let loadingMore = false;

  function maybeLoadMore() {
    if (!ipc.isTauri || threadOpen || view !== "mail" || folder === "settings") return;
    if (!hasMoreRows || loadingMore) return;
    const el = scrollEl;
    if (!el || el.scrollTop + el.clientHeight < el.scrollHeight - 600) return;
    loadingMore = true;
    listLimit += PAGE;
    refreshLive()
      .catch((e) => console.error("load more failed", e))
      .finally(() => (loadingMore = false));
  }
  let liveLabels: ipc.BackendLabel[] = $state([]);
  let liveTriageLabels: ipc.BackendTriageLabel[] = $state([]);
  // Jev triage filter (topbar expand icon next to the folder title) —
  // null = no filter, else a BackendTriageLabel id. Not persisted; resets
  // to "All" on relaunch like the other transient view filters.
  let activeTriageFilter: string | null = $state(null);

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

  // New-mail desktop notifications: thread id -> last_msg_at we've already
  // notified about. Keyed by thread (not "unread"), so a reply on an
  // existing thread (same id, later last_msg_at) still counts as new mail,
  // while a local mark-unread on an already-seen thread does not.
  const notifiedThreads = new Map<string, number>();
  let notifyBaseline = false;
  async function notifyNewMail(threads: ipc.BackendThread[]) {
    if (!notifyBaseline) {
      // First load: seed the baseline silently, don't notify for mail that
      // was already sitting in the inbox before the app opened.
      for (const t of threads) notifiedThreads.set(t.id, t.last_msg_at);
      notifyBaseline = true;
      return;
    }
    const arrivals = threads.filter((t) => {
      const prev = notifiedThreads.get(t.id);
      return !t.is_read && (prev === undefined || t.last_msg_at > prev);
    });
    for (const t of threads) notifiedThreads.set(t.id, t.last_msg_at);
    if (!arrivals.length || (await getCurrentWindow().isFocused())) return;
    let granted = await isPermissionGranted();
    if (!granted) granted = (await requestPermission()) === "granted";
    if (!granted) return;
    for (const t of arrivals.slice(0, 5)) {
      sendNotification({ title: t.from_summary || "New mail", body: t.subject || "(no subject)" });
    }
  }

  // Live-mode sidebar badge counts (folders + labels), one backend
  // round-trip per refresh — see counts below.
  let liveCounts: Record<string, number> = $state({});

  // Live mode: inside Tauri the mock seed is replaced by real store data.
  async function refreshLive() {
    const f = folder;
    const filter = filterFor(f);
    const wantFolder = filter !== null && filter !== "inbox";
    const [accounts, threads, folderThreads, scheduled, labels, unreadCounts, triageLabels] = await Promise.all([
      ipc.listAccounts(),
      ipc.listThreads(undefined, undefined, undefined, listLimit),
      wantFolder
        ? ipc.listThreads(filter!, undefined, undefined, listLimit)
        : Promise.resolve([] as ipc.BackendThread[]),
      ipc.listScheduled(),
      ipc.listLabels(),
      ipc.unreadCounts(unified ? undefined : activeAccountId),
      ipc.listTriageLabels(),
    ]);
    liveCounts = unreadCounts;
    liveTriageLabels = triageLabels;
    notifyNewMail(threads);
    liveAccounts = accounts.map((a) => ({
      id: a.id,
      email: a.email,
      label: a.display_name,
      tag: a.color,
      avatarUrl: a.avatar_url ?? undefined,
      signature: a.signature,
    }));
    liveLabels = labels;
    // A short page means the folder is exhausted — stop raising the limit.
    hasMoreRows = (wantFolder ? folderThreads : threads).length >= listLimit;
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
  // Opening search starts at the top of the view.
  $effect(() => {
    if (view === "search") requestAnimationFrame(() => scrollEl?.scrollTo({ top: 0 }));
  });

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

  /** Subsequence fuzzy match (VS Code palette / fzf-lite style): every query
   *  char must appear in order; contiguous runs score higher. null = no match. */
  function fuzzyScore(query: string, target: string): number | null {
    const q = query.toLowerCase();
    const t = target.toLowerCase();
    let qi = 0;
    let score = 0;
    let lastMatch = -1;
    for (let ti = 0; ti < t.length && qi < q.length; ti++) {
      if (t[ti] === q[qi]) {
        score += lastMatch === ti - 1 ? 3 : 1;
        lastMatch = ti;
        qi++;
      }
    }
    return qi === q.length ? score : null;
  }

  const emails = $derived.by(() => {
    // Calendar view: only scheduled mail, ascending by schedule (matches the
    // grouped render order so j/k navigation follows the visual order).
    const base =
      view === "calendar"
        ? emailsData
            .filter((e) => e.scheduledAt !== undefined)
            .filter((e) => schedFilter === "all" || !e.done)
            .filter((e) => activeTriageFilter === null || (e.triageLabelIds ?? []).includes(activeTriageFilter))
            .sort((a, b) => (a.scheduledAt ?? 0) - (b.scheduledAt ?? 0))
        : emailsData
            .filter((e) => (folder === "all" ? true : e.folder === folder))
            .filter((e) => inboxFilter === "all" || e.unread)
            .filter((e) => activeTriageFilter === null || (e.triageLabelIds ?? []).includes(activeTriageFilter));
    const mapped = base
      .filter((e) => unified || e.accountId === activeAccountId)
      .filter((e) => !attachmentOnly || e.attachment)
      .filter((e) => {
        if (view === "calendar" || dateFilter === "all" || e.lastMsgAt === undefined) return true;
        const startOfToday = new Date().setHours(0, 0, 0, 0);
        const days = dateFilter === "today" ? 0 : dateFilter === "week" ? 6 : 29;
        return e.lastMsgAt >= startOfToday - days * 86_400_000;
      })
      .map((e) =>
        // The ring only helps once there's more than one account to tell apart —
        // with a single account it's a uniform, purely decorative outline.
        unified && accounts.length > 1
          ? { ...e, accountTag: accounts.find((a) => a.id === e.accountId)?.tag }
          : e,
      );
    // Filters & sorting row: "newest" is each branch's natural order above,
    // "oldest" reverses it, "unread" stably promotes unread items without
    // otherwise reordering (Array#sort is stable).
    const ordered =
      emailSortOrder === "oldest"
        ? [...mapped].reverse()
        : emailSortOrder === "unread"
          ? [...mapped].sort((a, b) => Number(!!b.unread) - Number(!!a.unread))
          : mapped;
    const q = quickFilterOpen ? quickFilter.trim() : "";
    if (!q) return ordered;
    // Fuzzy filter over what's already loaded — client-side, no backend call.
    // Subsequence fuzzy on from/subject (short fields, typo-tolerant reads
    // well); the body snippet is prose — a 4-char subsequence matches almost
    // any paragraph, so it's a plain substring check instead, and ranked
    // below a real subject/sender match rather than fuzzy-scored itself.
    const ql = q.toLowerCase();
    return ordered
      .map((e) => {
        const subj = fuzzyScore(q, e.subject);
        const from = fuzzyScore(q, e.from);
        const score = subj !== null ? subj + 20 : from !== null ? from + 10 : e.snippet.toLowerCase().includes(ql) ? 0 : null;
        return score === null ? null : { e, score };
      })
      .filter((x): x is { e: Email; score: number } => x !== null)
      .sort((a, b) => b.score - a.score)
      .map((x) => x.e);
  });
  const email = $derived(
    emails.find((e) => e.id === selectedId) ?? emailsData.find((e) => e.id === selectedId),
  );
  // Backend-computed unread counts in live mode (every folder + label,
  // account-scoped like the rest of the view); a small inbox-only mock in
  // browser dev mode.
  const counts = $derived(
    ipc.isTauri && liveAccounts.length
      ? liveCounts
      : { inbox: EMAILS_SEED.filter((e) => e.folder === "inbox" && e.unread).length },
  );
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
    // Unchecking "done": restore to inbox immediately, no undo ceremony
    // (mirrors InboxList's clickDone "unchecking: no ceremony") — the row
    // stays visible with done flipped off, unlike mark-done/delete below
    // which drop the row from the current list entirely.
    if (em && action === "done" && em.done) {
      emailsData = emailsData.map((e) => (e.id === id ? { ...e, done: false } : e));
      if (ipc.isTauri) {
        ipc.mutate(em.accountId, { kind: "unarchive", thread_id: id } as const).catch((e) => {
          console.error("mutate failed", e);
          toast("danger", "Could not restore to inbox", String(e));
          emailsData = emailsData.map((e2) => (e2.id === id ? { ...e2, done: true } : e2));
        });
      }
      return;
    }
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
    if (em && action === "pin") {
      // Pin == Gmail star. Optimistic flip stays; the star mutation makes it
      // survive refresh and sync to Gmail's Starred (both directions — delta
      // sync refreshes the label union).
      const starred = !em.pinned;
      const flip = (ls: string[] | undefined) => {
        const rest = (ls ?? []).filter((l) => l !== "STARRED");
        return starred ? [...rest, "STARRED"] : rest;
      };
      emailsData = emailsData.map((e) =>
        e.id === id ? { ...e, pinned: starred, labels: flip(e.labels) } : e,
      );
      if (ipc.isTauri) {
        ipc.mutate(em.accountId, { kind: "star", thread_id: id, starred }).catch((e) => {
          console.error("mutate failed", e);
          toast("danger", starred ? "Could not pin" : "Could not unpin", String(e));
        });
      }
      return;
    }
    if (em && action === "reply") {
      openThread(id, true);
      return;
    }
    if (em && action === "forward") {
      forwardEmail(id);
      return;
    }
    console.log(id, action);
  }

  // Minimal forwarding: composer prefilled with "Fwd: <subject>" and a
  // plaintext copy of the latest message under the classic forwarded-message
  // header. Recipients start empty; reuses the send-undo composer plumbing.
  async function forwardEmail(id: string) {
    await loadBodies(id).catch(() => {});
    const em = emailsData.find((e) => e.id === id);
    if (!em) return;
    const last = em.thread?.[em.thread.length - 1];
    // Plaintext only — HTML messages use their text/plain alternative when
    // present, else fall back to the (truncated) snippet preview.
    const plain = last
      ? last.html
        ? (last.bodyText ?? last.snippet)
        : last.body
      : em.html
        ? em.snippet
        : (em.body ?? em.snippet);
    const header = [
      "---------- Forwarded message ----------",
      `From: ${last?.from ?? em.from}${last?.fromAddr ? ` <${last.fromAddr}>` : ""}`,
      `Date: ${last?.fullDate ?? em.fullDate ?? em.time}`,
      `Subject: ${em.subject}`,
    ].join("\n");
    composeDraft = {
      accountId: em.accountId,
      to: [],
      cc: [],
      bcc: [],
      subject: /^fwd:/i.test(em.subject) ? em.subject : `Fwd: ${em.subject}`,
      body: `\n\n${header}\n\n${plain}`,
    };
    composeOpen = true;
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

  /// Manual label edit (footer/header "+" menu or badge ×) — optimistic,
  /// sticky on the backend (survives future auto-classification).
  function setTriageLabels(id: string, labelIds: string[]) {
    const em = emailsData.find((e) => e.id === id);
    if (!em) return;
    const previous = em.triageLabelIds;
    emailsData = emailsData.map((e) => (e.id === id ? { ...e, triageLabelIds: labelIds } : e));
    if (!ipc.isTauri) return;
    ipc.setManualTriageLabels(id, labelIds).catch((e) => {
      console.error("set_manual_triage_labels failed", e);
      toast("danger", "Could not update labels", String(e));
      emailsData = emailsData.map((x) => (x.id === id ? { ...x, triageLabelIds: previous } : x));
    });
  }

  function switchView(v: "mail" | "calendar") {
    if (view === v) return;
    view = v;
    selectedId = null;
    threadOpen = false;
    fullscreen = false;
    closeQuickFilter();
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
          body_html: data.bodyHtml ?? null,
          attachments: (data.attachments ?? []).map(({ filename, mime_type, data_b64 }) => ({
            filename,
            mime_type,
            data_b64,
          })),
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

  function sendReply(em: Email, msg: ThreadMsg, data: ReplySendData) {
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
          body_text: data.body,
          body_html: data.bodyHtml ?? null,
          attachments: (data.attachments ?? []).map(({ filename, mime_type, data_b64 }) => ({
            filename,
            mime_type,
            data_b64,
          })),
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
            .writeText(data.body)
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

  function toggleSelect(id: string) {
    const next = new Set(selectedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    selectedIds = next;
  }

  function toggleSelectAll() {
    selectedIds = selectedIds.size === emails.length ? new Set() : new Set(emails.map((e) => e.id));
  }

  function clearSelection() {
    selectedIds = new Set();
  }

  // Loops the existing single-row action (own toast + optimistic update +
  // deferred undo-able mutate) over the checked set — reuses all of that
  // machinery instead of a parallel batched-mutation path.
  // ponytail: one toast per row (no combined "N archived" summary/undo) —
  // upgrade to a batched toast if selecting dozens at once proves noisy.
  function bulkAction(action: string) {
    for (const id of selectedIds) onEmailAction(id, action);
    clearSelection();
  }

  // A folder/account/view switch — or opening a thread — invalidates any
  // checked rows from the previous list; never let a stale selection drive
  // a bulk action against rows that are no longer shown.
  $effect(() => {
    void folder;
    void unified;
    void activeAccountId;
    void view;
    void threadOpen;
    selectedIds = new Set();
  });

  function openThread(id: string, reply = false) {
    if (reply) threadReplyStart++;
    else if (selectedId !== id || !threadOpen) threadReplyStart = 0;
    selectedId = id;
    threadOpen = true;
    loadBodies(id);
    closeQuickFilter();
    // Fresh read starts at the top, not wherever the list was scrolled.
    requestAnimationFrame(() => scrollEl?.scrollTo({ top: 0 }));
  }

  function selectFolder(f: string) {
    closeQuickFilter();
    // Instant switch: surface the last fetched rows for this folder now; the
    // folder-tracking $effect refetches right after.
    if (ipc.isTauri && f !== folder) {
      const cached = folderCache.get(f)?.filter((e) => !pendingUndo.has(e.id));
      if (cached?.length) {
        const ids = new Set(cached.map((e) => e.id));
        emailsData = [...cached, ...emailsData.filter((e) => !ids.has(e.id))];
      }
    }
    if (f !== folder) {
      listLimit = PAGE;
      hasMoreRows = true;
    }
    folder = f;
    view = "mail";
    selectedId = null;
    threadOpen = false;
  }

  // Search hits can be threads outside the inbox list (archived etc.) —
  // merge them in so ThreadView can find the email until the next refresh.
  function openSearchResult(t: ipc.BackendThread) {
    closeSearch();
    if (!emailsData.some((e) => e.id === t.id)) {
      emailsData = [...emailsData, ipc.threadToEmail(t)];
    }
    openThread(t.id);
  }

  // Stale reply-start must not leak into the next thread open.
  $effect(() => {
    if (!threadOpen) threadReplyStart = 0;
  });

  function closePalette() {
    paletteOpen = false;
    paletteStage = null;
    paletteStageCtx = null;
  }

  const LABEL_D =
    "M20.6 12.3l-8-8A2 2 0 0011.2 3.7L4 4v7.2a2 2 0 00.6 1.4l8 8a2 2 0 002.8 0l5.2-5.2a2 2 0 000-2.8zM8 8h.01";

  // Palette/shortcut target: the open thread wins, else the keyboard cursor,
  // else the selected row.
  function actionTarget(): Email | null {
    const id = threadOpen ? selectedId : (cursorId ?? selectedId);
    return emailsData.find((e) => e.id === id) ?? null;
  }

  function openLabelStage(mode: "label" | "move", em: Email) {
    const account = liveLabels.filter(
      (l) => l.account_id === em.accountId && !l.id.startsWith("CATEGORY_"),
    );
    // Browser demo: fall back to the mock label defs so the flow is visible.
    const all = account.length
      ? account.map((l) => ({ id: l.id, name: l.name }))
      : LABELS.map((l) => ({ id: l.key, name: l.label }));
    const has = new Set(em.labels ?? []);
    const items =
      mode === "move"
        ? all.map((l) => ({ key: `add:${l.id}`, label: l.name, d: LABEL_D }))
        : [
            ...all
              .filter((l) => !has.has(l.id))
              .map((l) => ({ key: `add:${l.id}`, label: l.name, d: LABEL_D })),
            ...all
              .filter((l) => has.has(l.id))
              .map((l) => ({ key: `remove:${l.id}`, label: `Remove ${l.name}`, d: LABEL_D })),
          ];
    if (!items.length) {
      closePalette();
      toast("info", "No labels", "This account has no labels yet");
      return;
    }
    paletteStageCtx = { mode, targetId: em.id };
    paletteStage = {
      title: mode === "move" ? "Move to" : "Label",
      items,
    };
    paletteOpen = true;
  }

  function applyStageAction(key: string) {
    const ctx = paletteStageCtx;
    closePalette();
    if (!ctx) return;
    const em = emailsData.find((e) => e.id === ctx.targetId);
    if (!em) return;
    const add = key.startsWith("add:");
    const labelId = key.slice(add ? 4 : 7);
    const name =
      liveLabels.find((l) => l.account_id === em.accountId && l.id === labelId)?.name ??
      LABELS.find((l) => l.key === labelId)?.label ??
      labelId;
    // Optimistic label flip; the backend confirms via threads_updated.
    const rest = (em.labels ?? []).filter((l) => l !== labelId);
    const next = add ? [...rest, labelId] : rest;
    emailsData = emailsData.map((e) => (e.id === em.id ? { ...e, labels: next } : e));
    if (ipc.isTauri) {
      ipc
        .mutate(em.accountId, { kind: "modify_label", thread_id: em.id, label_id: labelId, add })
        .catch((e) => {
          console.error("mutate failed", e);
          toast("danger", "Could not update label", String(e));
        });
    }
    if (ctx.mode === "move") {
      // Classic Gmail move: apply the label AND archive (remove INBOX). The
      // archive rides the usual deferred-undo path and shows its own toast.
      // In Trash/Spam the archive half is a guarded no-op (see onEmailAction)
      // — the label still applies, so say that instead of silently not moving.
      if (folder === "trash" || folder === "spam") {
        toast("info", "Labeled, not moved", `${name} added — mail stays in ${folder === "trash" ? "Trash" : "Spam"}`);
        return;
      }
      if (threadOpen) {
        threadOpen = false;
        fullscreen = false;
      }
      onEmailAction(em.id, "done");
    } else {
      toast("success", add ? "Label added" : "Label removed", name);
    }
  }

  function onPaletteAction(key: string) {
    if (paletteStage) {
      applyStageAction(key);
      return;
    }
    if (key === "compose") {
      closePalette();
      composeOpen = true;
      return;
    }
    if (key === "inbox") {
      closePalette();
      selectFolder("inbox");
      return;
    }
    if (key === "unified") {
      closePalette();
      unified = true;
      return;
    }
    const em = actionTarget();
    if (!em) {
      closePalette();
      toast("info", "Select an email first");
      return;
    }
    if (key === "label" || key === "move") {
      // Keeps the palette open — swaps in the stage-2 label list.
      openLabelStage(key, em);
      return;
    }
    closePalette();
    if (key === "done" || key === "delete") {
      if (threadOpen) {
        threadOpen = false;
        fullscreen = false;
      }
      onEmailAction(em.id, key);
    } else if (key === "star") {
      onEmailAction(em.id, "pin");
    } else if (key === "remind") {
      // The popover lives in InboxList — close the thread first so the list
      // (and the anchor row) is mounted before the request lands.
      if (threadOpen) {
        threadOpen = false;
        fullscreen = false;
      }
      remindRequestId = em.id;
    } else if (key === "reply") {
      openThread(em.id, true);
    } else if (key === "forward") {
      forwardEmail(em.id);
    }
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

  // Timestamp of the last bare 'g' keypress (g-i / g-u chords).
  let pendingG = 0;

  function onKey(ev: KeyboardEvent) {
    if ((ev.metaKey || ev.ctrlKey) && ev.key.toLowerCase() === "k") {
      ev.preventDefault();
      paletteOpen = true;
      return;
    }
    // The search overlay owns the keyboard, but Escape must close it even
    // when focus has left its input (e.g. after clicking overlay whitespace).
    if (view === "search") {
      if (ev.key === "Escape") {
        ev.preventDefault();
        closeSearch();
      }
      return;
    }
    // Settings modal: Escape closes; everything else is inert.
    if (settingsOpen) {
      if (ev.key === "Escape") settingsOpen = false;
      return;
    }
    // List navigation — never while typing or while an overlay owns the keyboard.
    if (isEditable(ev.target) || paletteOpen || composeOpen) return;
    if (ev.key === "/") {
      ev.preventDefault();
      // A thread hides the list — quick-filtering it would have no visible
      // target, so '/' falls back to full search in that context.
      if (threadOpen) openSearch();
      else openQuickFilter();
      return;
    }
    if (ev.key === "Escape") {
      if (selectedIds.size > 0) {
        clearSelection();
      } else if (threadOpen) {
        threadOpen = false;
        fullscreen = false;
      } else if (selectedId !== null) {
        selectedId = null;
      } else if (cursorId !== null) {
        cursorId = null;
      }
      return;
    }
    if (threadOpen) return;
    // OS chords (Cmd+C copy, Cmd+F find, Cmd+R reload…) must never trigger
    // the single-letter shortcuts below.
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    // 'g' prefix chords (g-i inbox, g-u unified) with a ~1s window.
    if (ev.key === "g") {
      pendingG = Date.now();
      return;
    }
    // Any other key consumes the chord — g,e,u must mark-unread, not navigate.
    const gArmed = Date.now() - pendingG < 1000;
    pendingG = 0;
    if (gArmed && (ev.key === "i" || ev.key === "u")) {
      ev.preventDefault();
      if (ev.key === "i") selectFolder("inbox");
      else unified = true;
      return;
    }
    if (ev.key === "c") {
      ev.preventDefault();
      composeOpen = true;
      return;
    }
    const actId = cursorId ?? selectedId;
    if (ev.key === "x" && actId !== null) {
      // Gmail-style: check/uncheck the cursor row without opening it.
      ev.preventDefault();
      toggleSelect(actId);
      return;
    }
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
    if (ev.key === "s" && actId !== null) {
      ev.preventDefault();
      onEmailAction(actId, "pin");
      return;
    }
    if (ev.key === "r" && actId !== null) {
      ev.preventDefault();
      openThread(actId, true);
      return;
    }
    if (ev.key === "f" && actId !== null) {
      ev.preventDefault();
      forwardEmail(actId);
      return;
    }
    if (ev.key === "h" && actId !== null) {
      // Remind popover — same path as the palette's "Remind me".
      ev.preventDefault();
      remindRequestId = actId;
      return;
    }
    if ((ev.key === "l" || ev.key === "v") && actId !== null) {
      // Pre-staged palette: jump straight to the label / move picker.
      ev.preventDefault();
      const em = emailsData.find((e) => e.id === actId);
      if (em) openLabelStage(ev.key === "l" ? "label" : "move", em);
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
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <header
    class="apphead"
    onmousedown={(ev) => {
      // Explicit drag: the data-tauri-drag-region attribute proved unreliable.
      if (!ipc.isTauri || ev.button !== 0) return;
      if (ev.detail === 2) {
        getCurrentWindow().toggleMaximize();
      } else {
        getCurrentWindow().startDragging();
      }
    }}
  >
    <span class="apphead-title">Hey Pigeon</span>
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
        onclick={() => {
          if (view !== "mail") switchView("mail");
        }}
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
      <button class="rail-btn" class:active={view === "search"} title="Search" onclick={openSearch}>
        <Icon d="M11 3a8 8 0 100 16 8 8 0 000-16zM21 21l-4.35-4.35" size={17} />
      </button>
    </div>
    <button class="rail-btn rail-cmdk" title="Command palette (Cmd+K)" onclick={() => (paletteOpen = true)}>
      <Icon d="M18 3a3 3 0 0 0-3 3v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 0 0-3-3 3 3 0 0 0-3 3 3 3 0 0 0 3 3h12a3 3 0 1 0-3-3z" size={16} />
    </button>
    <button
      class="rail-btn rail-settings"
      class:active={settingsOpen}
      title="Settings"
      onclick={() => (settingsOpen = true)}
    >
      <Icon
        d="M12 15a3 3 0 100-6 3 3 0 000 6z M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 11-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 11-4 0v-.09a1.65 1.65 0 00-1-1.51 1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 11-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 110-4h.09a1.65 1.65 0 001.51-1 1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 112.83-2.83l.06.06a1.65 1.65 0 001.82.33h0A1.65 1.65 0 0010 3.09V3a2 2 0 114 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 112.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82v0c.27.6.85 1 1.51 1H21a2 2 0 110 4h-.09a1.65 1.65 0 00-1.51 1z"
        size={16}
      />
    </button>
  </div>

  <div class="main">
    <div class="scroll" bind:this={scrollEl} onscroll={maybeLoadMore}>
      <div class="column">
        {#if view === "search"}
          <SearchOverlay open {accounts} onClose={closeSearch} onOpen={openSearchResult} />
        {:else}
        {#if !fullscreen}
          <div class="topbar">
            {#if selectedIds.size > 0 && !threadOpen}
              <div class="bulk-bar">
                <Tooltip label={selectedIds.size === emails.length ? "Deselect all" : "Select all"} side="bottom">
                  <button class="master-check" class:all={selectedIds.size === emails.length} onclick={toggleSelectAll}>
                    {#if selectedIds.size === emails.length}
                      <Icon d="M20 6L9 17l-5-5" size={11} strokeWidth={2.6} />
                    {/if}
                  </button>
                </Tooltip>
                <span class="bulk-count">{selectedIds.size} selected</span>
                <div class="spacer"></div>
                <Tooltip label="Mark done" side="bottom">
                  <IconButton label="Mark done" onclick={() => bulkAction("done")}>
                    <Icon d="M20 6L9 17l-5-5" size={15} />
                  </IconButton>
                </Tooltip>
                <Tooltip label="Mark unread" side="bottom">
                  <IconButton label="Mark unread" onclick={() => bulkAction("unread")}>
                    <Icon d="M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z" size={15} />
                  </IconButton>
                </Tooltip>
                <Tooltip label="Pin" side="bottom">
                  <IconButton
                    label="Pin"
                    onclick={() => bulkAction("pin")}
                  >
                    <Icon
                      d="M12 17v5M9 10.76a2 2 0 01-1.11 1.79l-1.78.9A2 2 0 005 15.24V16a1 1 0 001 1h12a1 1 0 001-1v-.76a2 2 0 00-1.11-1.79l-1.78-.9A2 2 0 0115 10.76V6h1a2 2 0 000-4H8a2 2 0 000 4h1z"
                      size={15}
                    />
                  </IconButton>
                </Tooltip>
                <Tooltip label="Delete" side="bottom">
                  <IconButton label="Delete" onclick={() => bulkAction("delete")}>
                    <Icon d="M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13" size={15} />
                  </IconButton>
                </Tooltip>
                <Tooltip label="Clear selection" side="bottom">
                  <IconButton label="Clear selection" onclick={clearSelection}>
                    <Icon d="M6 6l12 12M18 6L6 18" size={14} />
                  </IconButton>
                </Tooltip>
              </div>
            {:else}
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
            <div class="title-row">
              <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
              <span
                class="title"
                class:static={threadOpen}
                class:tab-inactive={activeTriageFilter !== null}
                onclick={() => {
                  if (threadOpen) return;
                  folder = "inbox";
                  unified = true;
                  activeTriageFilter = null;
                }}
              >
                {title}
                {#if !threadOpen}
                  <span class="count">{emails.length}</span>
                {/if}
              </span>
              {#if !threadOpen && view === "mail"}
                <TriageFilter
                  labels={liveTriageLabels}
                  activeId={activeTriageFilter}
                  onSelect={(id) => (activeTriageFilter = id)}
                />
              {/if}
            </div>
            <div class="spacer"></div>
            {#if !threadOpen}
              <div class="topbar-actions">
                <div class="topbar-actions-col">
                  {#if view === "calendar"}
                    <span class="topbar-filter">
                      <SegmentedControl
                        size="sm"
                        options={[
                          { value: "all", d: "M4 6h16M4 12h16M4 18h16", title: "All" },
                          { value: "active", d: "M12 5a7 7 0 100 14 7 7 0 000-14z", title: "Hide done" },
                        ]}
                        value={schedFilter}
                        onchange={setSchedFilter}
                      />
                    </span>
                  {:else if view === "mail"}
                    <span class="topbar-filter">
                      <SegmentedControl
                        size="sm"
                        options={[
                          { value: "all", d: "M4 6h16M4 12h16M4 18h16", title: "All" },
                          {
                            value: "unread",
                            d: "M12 12m-5 0a5 5 0 1010 0 5 5 0 10-10 0",
                            filled: true,
                            title: "Unread only",
                          },
                        ]}
                        value={inboxFilter}
                        onchange={setInboxFilter}
                      />
                    </span>
                  {/if}
                  <button
                    class="filter-toggle"
                    class:active={sortFilterOpen || hasNonDefaultSortFilter}
                    title={sortFilterOpen ? "Hide filters & sorting" : "Filters & sorting"}
                    onclick={() => (sortFilterOpen = !sortFilterOpen)}
                  >
                    <Icon d="M22 3H2l8 9.46V19l4 2v-8.54L22 3z" size={13} />
                    <span>Filters</span>
                  </button>
                </div>
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
            {/if}
          </div>
          {#if quickFilterOpen}
            <div class="quick-filter-bar">
              <Icon d="M11 4a7 7 0 105.6 11.2l4.2 4.2" size={15} />
              <!-- svelte-ignore a11y_autofocus -->
              <input
                autofocus
                class="quick-filter-input"
                placeholder="Filter this view…"
                autocomplete="off"
                autocorrect="off"
                autocapitalize="off"
                spellcheck="false"
                bind:value={quickFilter}
                onkeydown={(ev) => {
                  if (ev.key === "Escape") {
                    ev.preventDefault();
                    closeQuickFilter();
                  } else if (ev.key === "ArrowDown" && emails.length) {
                    // Hand off to the list: focus the first (filtered) row so
                    // j/k/ArrowDown/Enter continue navigating it from there.
                    ev.preventDefault();
                    selectedId = null;
                    cursorId = emails[0].id;
                    (ev.currentTarget as HTMLInputElement).blur();
                  }
                }}
              />
              {#if quickFilter.trim()}<span class="quick-filter-count">{emails.length}</span>{/if}
              <button class="quick-filter-close" aria-label="Close filter" onclick={closeQuickFilter}>
                <Icon d="M6 6l12 12M18 6L6 18" size={14} />
              </button>
            </div>
          {/if}
          {#if sortFilterOpen && !threadOpen}
            <div class="sort-filter-bar">
              <span class="sort-filter-label">Sort</span>
              <SegmentedControl
                size="sm"
                options={[
                  { value: "newest", label: "Newest" },
                  { value: "oldest", label: "Oldest" },
                  { value: "unread", label: "Unread first" },
                ]}
                value={emailSortOrder}
                onchange={setEmailSortOrder}
              />
              {#if view === "mail"}
                <span class="sort-filter-sep"></span>
                <Tooltip label="Unread only" side="bottom">
                  <IconButton
                    size="sm"
                    active={inboxFilter === "unread"}
                    label="Unread only"
                    onclick={() => setInboxFilter(inboxFilter === "unread" ? "all" : "unread")}
                  >
                    <Icon
                      d="M12 12m-5 0a5 5 0 1010 0 5 5 0 10-10 0"
                      size={14}
                      fill={inboxFilter === "unread" ? "var(--accent-highlight)" : "none"}
                      stroke={inboxFilter === "unread" ? "var(--accent-highlight)" : "currentColor"}
                    />
                  </IconButton>
                </Tooltip>
              {/if}
              {#if view !== "calendar"}
                <span class="sort-filter-sep"></span>
                <span class="sort-filter-label">Date</span>
                <SegmentedControl
                  size="sm"
                  options={[
                    { value: "all", label: "All" },
                    { value: "today", label: "Today" },
                    { value: "week", label: "This week" },
                    { value: "month", label: "This month" },
                  ]}
                  value={dateFilter}
                  onchange={setDateFilter}
                />
              {/if}
              <span class="sort-filter-sep"></span>
              <Tooltip label="Has attachment" side="bottom">
                <IconButton size="sm" active={attachmentOnly} label="Has attachment" onclick={() => setAttachmentOnly(!attachmentOnly)}>
                  <Icon
                    d="M21 12.5l-8.4 8.4a5 5 0 01-7-7l8.4-8.4a3.5 3.5 0 015 5l-7.9 7.9"
                    size={14}
                    stroke={attachmentOnly ? "var(--accent-highlight)" : "currentColor"}
                  />
                </IconButton>
              </Tooltip>
              {#if liveTriageLabels.length > 0}
                <span class="sort-filter-sep"></span>
                <span class="sort-filter-label">Label</span>
                <TriageFilter labels={liveTriageLabels} activeId={activeTriageFilter} onSelect={(id) => (activeTriageFilter = id)} />
              {/if}
            </div>
          {/if}
        {/if}
        {#if threadOpen}
          <ThreadView
            {email}
            onClose={() => {
              threadOpen = false;
              fullscreen = false;
            }}
            onSendReply={(msg, data) => email && sendReply(email, msg, data)}
            replySignature={email ? signatureFor(email.accountId) : undefined}
            {fullscreen}
            onToggleFullscreen={(v) => (fullscreen = v)}
            onToggleDone={() => email && onEmailAction(email.id, "done")}
            onForward={() => email && forwardEmail(email.id)}
            initialReplyOpen={threadReplyStart}
            triageLabels={liveTriageLabels}
            onSetTriageLabels={setTriageLabels}
            {autoSummarize}
          />
        {:else}
          <InboxList
            {emails}
            {selectedId}
            {cursorId}
            {selectedIds}
            mode={view === "calendar" ? "scheduled" : "inbox"}
            onSelect={selectEmail}
            onOpen={openThread}
            onAction={onEmailAction}
            onToggleSelect={toggleSelect}
            onSchedule={setSchedule}
            onSendReply={(em, data) => {
              const target = em.thread?.[em.thread.length - 1];
              if (target) sendReply(em, target, data);
            }}
            signatureFor={(em) => signatureFor(em.accountId)}
            {hoverActions}
            {pinListEnabled}
            {autoSummarize}
            {remindRequestId}
            onRemindHandled={() => (remindRequestId = null)}
            triageLabels={liveTriageLabels}
            onSetTriageLabels={setTriageLabels}
          />
          {#if emails.length === 0}
            <div class="empty">{view === "calendar" ? "Nothing scheduled" : "Nothing here yet"}</div>
          {/if}
        {/if}
        {/if}
      </div>
    </div>
  </div>

  <CommandPalette
    open={paletteOpen}
    stage={paletteStage}
    onClose={closePalette}
    onBack={() => {
      paletteStage = null;
      paletteStageCtx = null;
    }}
    onAction={onPaletteAction}
  />

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

  {#if view !== "search"}
    <button class="fab" title="Compose (c)" onclick={() => (composeOpen = true)}>
      <Icon d="M4 20l1-4L17 4l3 3L8 19l-4 1z" size={20} />
    </button>
  {/if}

  {#if settingsOpen}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div
      class="compose-backdrop"
      onmousedown={(ev) => {
        if (ev.target === ev.currentTarget) settingsOpen = false;
      }}
    >
      <div class="compose-modal settings-modal">
        <div class="compose-head">
          <span class="compose-title">Settings</span>
          <Tooltip label="Close" side="bottom">
            <IconButton size="sm" label="Close" onclick={() => (settingsOpen = false)}>
              <Icon d="M6 6l12 12M18 6L6 18" size={15} />
            </IconButton>
          </Tooltip>
        </div>
        <div class="compose-body">
          <Settings
            {accounts}
            {hoverActions}
            onHoverActionsChange={setHoverActions}
            {pinListEnabled}
            onPinListChange={setPinListEnabled}
            {autoSummarize}
            onAutoSummarizeChange={setAutoSummarize}
            onAddAccount={addAccount}
            onRemoveAccount={removeAccount}
            onUpdateAccount={updateAccount}
          />
        </div>
      </div>
    </div>
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
    width: 56px;
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    /* Sits directly on the gray canvas — no separate surface. */
    background: transparent;
    padding-top: 14px;
    gap: 6px;
    z-index: 40;
  }
  .rail-btn {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    justify-content: center;
    width: 38px;
    height: 38px;
    border-radius: 50%;
    padding: 0;
    transition: background var(--duration-fast) var(--ease-standard);
  }
  .rail-btn:hover {
    color: var(--text-primary);
    background: rgba(255, 255, 255, 0.6);
  }
  .rail-btn.active {
    color: var(--text-primary);
    background: var(--surface-card);
    box-shadow: var(--shadow-sm);
  }
  .rail-cmdk {
    margin-top: auto;
  }
  .rail-settings {
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
    /* Floating white card on the gray canvas. */
    background: var(--surface-card);
    margin: 0 10px 10px 0;
    border-radius: var(--radius-2xl);
    box-shadow: var(--shadow-xs);
    overflow: hidden;
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
    padding: 0 32px 40px;
    display: flex;
    flex-direction: column;
  }
  .topbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px 0 16px;
    /* Constant row height whether or not 36px icon buttons are present
       (settings/thread views hide them) — titles never shift. */
    min-height: 36px;
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
    /* Title centers on the traffic-light axis — equal space above/below. */
    height: 28px;
    flex-shrink: 0;
    position: relative;
    background: transparent;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .apphead-title {
    font-family: var(--font-display);
    font-weight: 800;
    font-size: 11px;
    letter-spacing: 0.02em;
    color: var(--text-secondary);
  }
  .title {
    cursor: pointer;
    font-family: var(--font-display);
    font-weight: 800;
    letter-spacing: -0.01em;
    font-size: 20px;
    color: var(--text-primary);
  }
  .title-row {
    display: flex;
    /* Text baselines match regardless of font-size — .topbar's own
       align-items:center would otherwise vertically center each box by
       height, leaving the smaller TriageFilter tabs sitting visibly
       higher than the title's baseline. */
    align-items: baseline;
    gap: 16px;
    min-width: 0;
  }
  .title.static {
    cursor: default;
  }
  /* Only one "tab" (this title, or a TriageFilter label) is bold at a
     time — Superhuman-style. */
  .title.tab-inactive {
    color: var(--text-tertiary);
  }
  /* iOS-style notification badge — fixed height/min-width doubles as the
     fix for the TriageFilter chevron jumping horizontally as the digit
     count changes (6 vs 15 vs 156). */
  .count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    box-sizing: border-box;
    min-width: 20px;
    height: 18px;
    padding: 0 6px;
    margin-left: -6px;
    border-radius: 999px;
    background: var(--tag-coral-fg);
    color: var(--white);
    font-variant-numeric: tabular-nums;
    font-size: 11px;
    font-weight: 700;
    position: relative;
    z-index: 1;
    top: -11px;
    box-shadow: 0 0 0 2px var(--bg-canvas);
  }
  /* A normal-sized search row below the title — not squeezed into the
     20px title row alongside the segmented control / Cmd+K button. */
  .quick-filter-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 0 14px;
    margin-top: -4px;
    border-bottom: 1px solid var(--border-subtle);
    margin-bottom: 8px;
    color: var(--text-tertiary);
  }
  .quick-filter-input {
    flex: 1;
    min-width: 0;
    border: none;
    outline: none;
    background: none;
    font-family: var(--font-body);
    font-size: 14px;
    color: var(--text-primary);
  }
  .quick-filter-input::placeholder {
    color: var(--text-tertiary);
  }
  .quick-filter-count {
    font-size: 14px;
    color: var(--text-tertiary);
    flex-shrink: 0;
  }
  .quick-filter-close {
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-tertiary);
    display: flex;
    padding: 4px;
    flex-shrink: 0;
  }
  .quick-filter-close:hover {
    color: var(--text-primary);
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
  /* Stacks the All/Unread (or All/Hide done) segmented control above the
     filters & sorting toggle, both right-aligned in the topbar's corner. */
  .topbar-actions-col {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 6px;
  }
  .topbar-filter {
    display: flex;
    align-items: center;
    font-size: 12.5px;
    color: var(--text-tertiary);
  }
  .topbar-filter:not(:last-child) {
    margin-right: 10px;
  }
  /* Stacked in .topbar-actions-col, not side-by-side — the horizontal gap
     above would otherwise pull the segmented control off the right edge
     that the filter-toggle button below it aligns to. */
  .topbar-actions-col .topbar-filter {
    margin-right: 0;
  }
  /* Filters & sorting toggle — same icon/label color language as the
     sidebar's nav-item pills (secondary by default, primary on hover,
     inverse on a solid pill when active). */
  .filter-toggle {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 28px;
    padding: 0 10px;
    border: none;
    background: none;
    border-radius: var(--radius-pill);
    cursor: pointer;
    color: var(--text-secondary);
    font-family: var(--font-body);
    font-size: 12px;
    font-weight: 600;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .filter-toggle:hover {
    background: var(--surface-card);
    box-shadow: var(--shadow-xs);
    color: var(--text-primary);
  }
  .filter-toggle.active {
    background: var(--surface-inverse);
    box-shadow: var(--shadow-sm);
    color: var(--text-inverse);
  }
  /* Filters & sorting row — same slot/pattern as .quick-filter-bar, opened
     by the toggle button below the topbar's segmented control. */
  .sort-filter-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 0 14px;
    margin-top: -4px;
    border-bottom: 1px solid var(--border-subtle);
    margin-bottom: 8px;
  }
  .sort-filter-label {
    font-family: var(--font-body);
    font-size: 12.5px;
    color: var(--text-tertiary);
  }
  .sort-filter-sep {
    width: 1px;
    height: 18px;
    background: var(--border-subtle);
  }
  /* Replaces the title/filter row while any row is checked. */
  .bulk-bar {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
  }
  .master-check {
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    border: 1.5px solid var(--border-default);
    border-radius: 3px;
    background: none;
    padding: 0;
    cursor: pointer;
    color: transparent;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .master-check.all {
    background: var(--surface-inverse);
    border-color: var(--surface-inverse);
    color: var(--text-inverse);
  }
  .bulk-count {
    font-family: var(--font-body);
    font-size: 13px;
    font-weight: 600;
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
    border-radius: var(--radius-2xl);
    box-shadow: var(--shadow-lg);
    width: 720px;
    max-width: 100%;
    height: min(680px, 88vh);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .settings-modal {
    width: 640px;
    height: min(720px, 88vh);
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
    font-weight: 800;
    letter-spacing: -0.01em;
    font-size: 17px;
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
  .fab {
    position: fixed;
    right: 30px;
    bottom: 28px;
    width: 54px;
    height: 54px;
    border-radius: 50%;
    border: none;
    background: var(--surface-inverse);
    color: var(--text-inverse);
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    box-shadow: var(--shadow-lg);
    z-index: 60;
    transition: transform var(--duration-fast) var(--ease-standard);
  }
  .fab:hover {
    transform: scale(1.07);
  }
  .toast-stack {
    position: fixed;
    /* Beside the compose FAB, bottom-aligned with it. */
    right: 96px;
    bottom: 28px;
    align-items: flex-end;
    display: flex;
    flex-direction: column;
    gap: 10px;
    z-index: 200;
  }
</style>
