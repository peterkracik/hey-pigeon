/** Global toast store — bottom-right notifications. */

export type ToastTone = "success" | "warning" | "danger" | "info";

export interface ToastItem {
  id: number;
  tone: ToastTone;
  title: string;
  description?: string;
}

let nextId = 1;

export const toasts = $state<ToastItem[]>([]);

export function toast(tone: ToastTone, title: string, description?: string) {
  const id = nextId++;
  toasts.push({ id, tone, title, description });
  setTimeout(() => dismissToast(id), tone === "danger" ? 7000 : 4000);
}

export function dismissToast(id: number) {
  const i = toasts.findIndex((t) => t.id === id);
  if (i !== -1) toasts.splice(i, 1);
}
