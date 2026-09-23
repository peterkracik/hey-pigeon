// Mock data layer — the seam where Tauri IPC (Rust core queries) plugs in later.
// UI is a projection: components read these shapes, never talk to Gmail.

export interface Account {
  id: string;
  email: string;
  label: string;
  tag: string;
  /** Provider profile photo (live mode). */
  avatarUrl?: string;
  /** Appended to composed mail from this account. */
  signature?: string;
}

export interface LabelDef {
  key: string;
  label: string;
  tag: string;
}

export interface Attachment {
  name: string;
  size: string;
}

export interface ThreadMsg {
  id: string;
  from: string;
  /** Bare email address for replies (live mode). */
  fromAddr?: string;
  isMe: boolean;
  /** Display-ready recipient list ("me" for the own address, live mode). */
  to?: string[];
  date: string;
  fullDate?: string;
  snippet: string;
  body: string;
  html?: boolean;
  /** text/plain alternative when body is HTML (live mode) — forwarding. */
  bodyText?: string;
  attachments?: Attachment[];
}

export interface Email {
  id: string;
  accountId: string;
  folder: string;
  from: string;
  /** Bare address of the latest sender (live mode) — avatar lookups. */
  fromAddr?: string;
  /** Epoch ms of the newest message (live mode) — date grouping. */
  lastMsgAt?: number;
  /** Local-only "remind me" schedule (epoch ms). Never synced to Gmail. */
  scheduledAt?: number;
  subject: string;
  snippet: string;
  time: string;
  unread: boolean;
  fullDate?: string;
  body?: string;
  html?: boolean;
  done?: boolean;
  pinned?: boolean;
  /** Gmail label-id union over the thread (live mode) — palette label ops. */
  labels?: string[];
  labelTag?: string;
  /** Local-only Jev triage priority (live mode). Never synced to Gmail. */
  priority?: "spam" | "low" | "medium" | "high";
  /** Local-only Jev triage label ids (live mode). Never synced to Gmail. */
  triageLabelIds?: string[];
  attachment?: boolean;
  attachments?: Attachment[];
  /** Messages in the thread (live mode) — >1 marks a conversation. */
  msgCount?: number;
  thread?: ThreadMsg[];
  accountTag?: string;
}

export interface EmailAction {
  key: string;
  label: string;
  d: string;
}

/** Predefined account colors — mirrors ACCOUNT_COLORS in the Rust backend. */
export const ACCOUNT_COLOR_TAGS = [
  "sky",
  "lavender",
  "mint",
  "amber",
  "coral",
] as const;

export const ACCOUNTS: Account[] = [
  { id: "a1", email: "peter@heypigeon.app", label: "Peter", tag: "sky" },
  { id: "a2", email: "team@heypigeon.app", label: "Team", tag: "lavender" },
];

export const LABELS: LabelDef[] = [
  { key: "label-invoice", label: "Invoice", tag: "amber" },
  { key: "label-marketing", label: "Marketing", tag: "coral" },
  { key: "label-projects", label: "Projects", tag: "mint" },
];

export const FOLDER_TITLES: Record<string, string> = {
  all: "All emails",
  inbox: "Inbox",
  starred: "Starred",
  sent: "Sent",
  drafts: "Drafts",
  archive: "Archive",
  spam: "Spam",
  trash: "Trash",
  scheduled: "Scheduled",
  settings: "Settings",
  "label-invoice": "Invoice",
  "label-marketing": "Marketing",
  "label-projects": "Projects",
};

export const EMAIL_ACTIONS: EmailAction[] = [
  {
    key: "delete",
    label: "Delete",
    d: "M4 7h16M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-9 0l1 13a1 1 0 001 1h8a1 1 0 001-1l1-13",
  },
  {
    key: "remind",
    label: "Remind me",
    d: "M12 8v5l3 2M12 3a9 9 0 100 18 9 9 0 000-18z",
  },
  {
    key: "spam",
    label: "Report spam",
    d: "M12 9v4m0 4h.01M10.3 3.9L2.7 17a2 2 0 001.7 3h15.2a2 2 0 001.7-3L13.7 3.9a2 2 0 00-3.4 0z",
  },
  { key: "reply", label: "Reply", d: "M9 17l-5-5 5-5M4 12h11a5 5 0 010 10h-1" },
  {
    key: "unread",
    label: "Mark unread",
    d: "M3 7l9 6 9-6M4 6h16a1 1 0 011 1v10a1 1 0 01-1 1H4a1 1 0 01-1-1V7a1 1 0 011-1z",
  },
  {
    key: "pin",
    label: "Pin",
    d: "M12 17v5M9 10.76a2 2 0 01-1.11 1.79l-1.78.9A2 2 0 005 15.24V16a1 1 0 001 1h12a1 1 0 001-1v-.76a2 2 0 00-1.11-1.79l-1.78-.9A2 2 0 0115 10.76V6h1a2 2 0 000-4H8a2 2 0 000 4h1z",
  },
];

export const CONTACTS = [
  { name: "Priya Nair", email: "priya.nair@acme.co" },
  { name: "Sam Okoye", email: "sam.okoye@gmail.com" },
  { name: "Ana Torres", email: "ana.torres@brightbooks.com" },
  { name: "Marcus Webb", email: "marcus.webb@webbandpartners.com" },
  { name: "Jordan Lee", email: "jordan.lee@linear.app" },
  { name: "Team", email: "team@heypigeon.app" },
];

const DIGEST_HTML = `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{margin:0;background:#F7F7F8;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#111318}
.wrap{max-width:600px;margin:0 auto;background:#fff}
.pad{padding:32px 36px}
h1,h2{margin:0;font-family:Georgia,'Times New Roman',serif}
p{margin:0 0 14px;line-height:1.6;font-size:15px;color:#33363E}
.btn{display:inline-block;background:#111318;color:#fff;text-decoration:none;padding:12px 22px;border-radius:8px;font-size:14px;font-weight:600}
.tag{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;padding:4px 10px;border-radius:999px}
.divider{height:1px;background:#EEEEF0}
.stat{text-align:center}
.stat .num{font-family:Georgia,serif;font-size:28px;font-weight:700;color:#111318}
.stat .lbl{font-size:12px;color:#75787F;margin-top:2px}
a{color:#111318}
</style></head>
<body>
<div class="wrap">
  <div style="background:#111318;padding:28px 36px;">
    <span style="font-family:Georgia,serif;font-weight:700;font-size:18px;color:#fff;letter-spacing:.01em">Hey Pigeon</span>
  </div>
  <div class="pad" style="padding-bottom:8px;">
    <span class="tag" style="background:#DDEAFB;color:#2A6BAE;">Weekly digest</span>
    <h1 style="font-size:26px;margin-top:14px;line-height:1.25;">What happened in your inbox this week</h1>
    <p style="margin-top:14px;">Hi Priya - here's a quick summary of activity across your accounts, plus a few things worth a look before Monday.</p>
  </div>
  <div class="divider"></div>
  <div class="pad" style="display:flex;gap:0;">
    <div class="stat" style="flex:1;"><div class="num">128</div><div class="lbl">Messages received</div></div>
    <div class="stat" style="flex:1;"><div class="num">34</div><div class="lbl">Replied to</div></div>
    <div class="stat" style="flex:1;"><div class="num">6</div><div class="lbl">Snoozed</div></div>
  </div>
  <div class="divider"></div>
  <div class="pad">
    <h2 style="font-size:18px;margin-bottom:14px;">Top threads waiting on you</h2>
    <p><strong>Marcus Webb</strong> - Contract renewal, sign by Friday. <em>3 days waiting.</em></p>
    <p><strong>Ana Torres</strong> - Invoice #4021 needs review. <em>1 day waiting.</em></p>
    <p><strong>Sam Okoye</strong> - Re: Dinner Friday? A quick yes/no would close this out.</p>
  </div>
  <div class="divider"></div>
  <div class="pad">
    <h2 style="font-size:18px;margin-bottom:14px;">Product notes</h2>
    <p><strong>Unified inbox</strong> - switch between accounts or view everything together from one list. Turn it on from the account switcher in the sidebar.</p>
    <p><strong>Command palette</strong> - press <code>Cmd+K</code> anywhere to archive, snooze, label, or jump to a folder without touching the mouse.</p>
    <p><strong>Resizable reading pane</strong> - drag the left edge of any open message to widen it, or expand to full screen for long threads.</p>
  </div>
  <div class="divider"></div>
  <div class="pad" style="text-align:center;background:#F7F7F8;">
    <p style="margin-bottom:18px;">Ready to clear the rest of your week?</p>
    <a class="btn" href="#">Open inbox</a>
  </div>
  <div class="pad" style="text-align:center;">
    <p style="font-size:12px;color:#9A9CA2;margin:0;">Hey Pigeon • You're receiving this because you subscribed to weekly digests.<br><a href="#" style="color:#9A9CA2;text-decoration:underline;">Unsubscribe</a> • <a href="#" style="color:#9A9CA2;text-decoration:underline;">Manage preferences</a></p>
  </div>
</div>
</body></html>`;

/** Mock schedule times so the calendar view is demoable in browser mode. */
function mockSchedule(dayOffset: number, hour: number): number {
  const d = new Date();
  d.setDate(d.getDate() + dayOffset);
  d.setHours(hour, 0, 0, 0);
  return d.getTime();
}

export const EMAILS_SEED: Email[] = [
  {
    id: "1",
    accountId: "a1",
    folder: "inbox",
    from: "Priya Nair",
    subject: "Q3 planning doc",
    snippet: "Could you take a look before Thursday standup...",
    time: "9:14 AM",
    unread: true,
    scheduledAt: mockSchedule(0, 18),
    thread: [
      {
        id: "t1",
        from: "Priya Nair",
        isMe: false,
        to: ["me", "sam@heypigeon.app", "ana@heypigeon.app"],
        date: "Mon",
        fullDate: "Mon, Aug 24, 2026, 2:08 PM",
        snippet:
          "Sharing the first draft of the Q3 plan, would love your eyes on it...",
        body: "Sharing the first draft of the Q3 plan, would love your eyes on it before we circulate to the team.",
      },
      {
        id: "t2",
        from: "Priya Nair",
        isMe: true,
        date: "Tue",
        fullDate: "Tue, Aug 25, 2026, 10:32 AM",
        snippet:
          "Skimmed it - timeline in section 2 looks tight, will comment...",
        body: "Skimmed it - the timeline in section 2 looks tight, I will leave comments by end of day.",
      },
      {
        id: "t3",
        from: "Priya Nair",
        isMe: false,
        to: ["me", "sam@heypigeon.app", "ana@heypigeon.app"],
        date: "Wed",
        fullDate: "Wed, Aug 26, 2026, 4:51 PM",
        snippet:
          "Thanks, updated based on your comments, one open question left...",
        body: "Thanks, I updated the doc based on your comments. One open question left on staffing for the migration workstream.",
      },
      {
        id: "t4",
        from: "Priya Nair",
        isMe: false,
        to: ["me", "sam@heypigeon.app"],
        date: "9:14 AM",
        fullDate: "Mon, Aug 31, 2026, 9:14 AM",
        snippet: "Could you take a look before Thursday's standup...",
        body: "Hi - could you take a look at the Q3 planning doc before Thursday's standup? Mainly want your read on the timeline in section 2.",
      },
    ],
  },
  {
    id: "2",
    accountId: "a2",
    folder: "inbox",
    from: "Linear",
    subject: "HI-1 moved to In Progress",
    snippet:
      'Jordan Lee updated the status of HI-1 "Redesign onboarding" from Todo to In Progress and left a comment about the new empty states...',
    time: "8:02 AM",
    fullDate: "Mon, Aug 31, 2026, 8:02 AM",
    unread: true,
    body: 'Jordan Lee moved HI-1 "Redesign onboarding" from Todo to In Progress.',
  },
  {
    id: "3",
    accountId: "a1",
    folder: "inbox",
    done: true,
    from: "Sam Okoye",
    subject: "Re: Dinner Friday?",
    snippet:
      "Works for me - 7pm at the usual spot? I can grab a table on the patio if the weather holds, otherwise inside is fine too...",
    time: "Yesterday",
    fullDate: "Sun, Aug 30, 2026, 6:47 PM",
    unread: false,
    body: "Works for me - 7pm at the usual spot? Let me know if that still works for you.",
  },
  {
    id: "4",
    accountId: "a1",
    folder: "inbox",
    from: "Hey Pigeon Team",
    subject: "What happened in your inbox this week",
    snippet: "Your weekly digest - top threads, product notes...",
    time: "Yesterday",
    fullDate: "Sun, Aug 30, 2026, 7:00 AM",
    unread: false,
    html: true,
    body: DIGEST_HTML,
  },
  {
    id: "5",
    accountId: "a2",
    folder: "inbox",
    pinned: true,
    scheduledAt: mockSchedule(1, 9),
    from: "Ana Torres",
    subject: "Invoice #4021",
    snippet:
      "Attached is the invoice for last month's work, broken down by hours and expenses - let me know if anything looks off before you send it to accounting...",
    time: "Mon",
    fullDate: "Mon, Aug 24, 2026, 11:20 AM",
    unread: false,
    labelTag: "amber",
    attachment: true,
    body: "Attached is the invoice for last month's work. Let me know if anything looks off.",
    attachments: [{ name: "Invoice-4021.pdf", size: "212 KB" }],
  },
  {
    id: "6",
    accountId: "a1",
    folder: "inbox",
    pinned: true,
    done: true,
    scheduledAt: mockSchedule(8, 9),
    from: "Marcus Webb",
    subject: "Contract renewal - sign by Friday",
    snippet:
      "Sending over the renewal for next quarter, terms are unchanged from last year aside from the updated billing address - happy to hop on a call if anything needs discussion...",
    time: "Mon",
    fullDate: "Mon, Aug 24, 2026, 3:45 PM",
    unread: false,
    labelTag: "mint",
    attachment: true,
    body: "Sending over the renewal for next quarter. Please sign and return by Friday if the terms look right.",
    attachments: [{ name: "Renewal-Q4-2026.pdf", size: "486 KB" }],
  },
  {
    id: "7",
    accountId: "a1",
    folder: "starred",
    from: "Priya Nair",
    subject: "Q3 planning doc",
    snippet: "Could you take a look before Thursday standup...",
    time: "9:14 AM",
    unread: false,
    body: "Hi - could you take a look at the Q3 planning doc before Thursday's standup?",
  },
];

// Initials rendering lives in ds/Avatar.svelte.
