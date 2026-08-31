// Tauri IPC seam. In the desktop app this replaces the mock data in data.ts;
// in a plain browser (npm run dev) the mock keeps working and isTauri is false.

import type { Email, ThreadMsg } from "./data";

export interface BackendAccount {
  id: string;
  email: string;
  display_name: string;
  color: string;
  history_id: string | null;
  avatar_url: string | null;
}

export interface BackendThread {
  id: string;
  account_id: string;
  subject: string;
  snippet: string;
  last_msg_at: number;
  is_read: boolean;
  is_inbox: boolean;
  is_archived: boolean;
  msg_count: number;
  from_summary: string;
  last_from_addr: string;
}

export interface BackendMessage {
  id: string;
  thread_id: string;
  account_id: string;
  from_addr: string;
  to_addrs: string[];
  date: number;
  snippet: string;
  body_html: string | null;
  body_text: string | null;
  label_ids: string[];
  is_read: boolean;
}

export type BackendMutation =
  | { kind: "archive"; thread_id: string }
  | { kind: "mark_read"; thread_id: string; read: boolean }
  | { kind: "trash"; thread_id: string }
  | {
      kind: "send";
      to: string[];
      cc: string[];
      bcc: string[];
      subject: string;
      body_text: string;
      reply_to_thread: string | null;
    };

import { invoke as tauriInvoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export const isTauri = "__TAURI_INTERNALS__" in globalThis;

function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!isTauri) return Promise.reject(new Error("not running inside Tauri"));
  return tauriInvoke<T>(cmd, args);
}

export const listAccounts = () => invoke<BackendAccount[]>("list_accounts");
export const listThreads = (
  accountId?: string,
  before?: number,
  limit?: number,
) => invoke<BackendThread[]>("list_threads", { accountId, before, limit });
export const getThread = (threadId: string) =>
  invoke<{ thread: BackendThread; messages: BackendMessage[] } | null>(
    "get_thread",
    { threadId },
  );
export const mutate = (accountId: string, mutation: BackendMutation) =>
  invoke<void>("mutate", { accountId, mutation });
export const syncNow = (accountId: string) =>
  invoke<number>("sync_now", { accountId });
/** Runs the browser consent flow; resolves with the connected email address. */
export const startGmailOauth = () => invoke<string>("start_gmail_oauth");

/** Subscribe to backend change events. Returns an unsubscribe function. */
export async function onThreadsUpdated(cb: () => void): Promise<() => void> {
  if (!isTauri) return () => {};
  return listen("threads_updated", cb);
}

// ---------------------------------------------------------------- mapping

function fmtTime(epochMs: number): string {
  const d = new Date(epochMs);
  const now = new Date();
  const sameDay = d.toDateString() === now.toDateString();
  if (sameDay)
    return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return "Yesterday";
  const days = (now.getTime() - epochMs) / 86_400_000;
  if (days < 7) return d.toLocaleDateString([], { weekday: "short" });
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

function fmtFull(epochMs: number): string {
  return new Date(epochMs).toLocaleDateString([], {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function threadToEmail(t: BackendThread): Email {
  return {
    id: t.id,
    accountId: t.account_id,
    folder: "inbox",
    from: t.from_summary,
    subject: t.subject,
    snippet: t.snippet,
    time: fmtTime(t.last_msg_at),
    fullDate: fmtFull(t.last_msg_at),
    unread: !t.is_read,
    fromAddr: t.last_from_addr || undefined,
  };
}

export function messagesToThreadMsgs(
  messages: BackendMessage[],
  myEmail: string,
): ThreadMsg[] {
  return messages.map((m) => ({
    id: m.id,
    from: m.from_addr.replace(/<.*>/, "").trim() || m.from_addr,
    fromAddr: m.from_addr.match(/<([^>]+)>/)?.[1] ?? m.from_addr,
    isMe: m.from_addr.includes(myEmail),
    date: fmtTime(m.date),
    fullDate: fmtFull(m.date),
    snippet: m.snippet,
    body: m.body_html ?? m.body_text ?? m.snippet,
    html: Boolean(m.body_html),
  }));
}
