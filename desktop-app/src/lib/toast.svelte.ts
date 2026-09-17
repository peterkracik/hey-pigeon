/** Global toast store — bottom-right notifications. */

export type ToastTone = "success" | "warning" | "danger" | "info";

export interface ToastItem {
  id: number;
  tone: ToastTone;
  title: string;
  description?: string;
  actionLabel?: string;
  onAction?: () => void;
}

export interface ToastOpts {
  actionLabel?: string;
  onAction?: () => void;
  duration?: number;
}

let nextId = 1;

export const toasts = $state<ToastItem[]>([]);

export function toast(tone: ToastTone, title: string, description?: string, opts?: ToastOpts) {
  const id = nextId++;
  // Invoking the action dismisses the toast first, then runs the callback.
  const onAction = opts?.onAction
    ? () => {
        dismissToast(id);
        opts.onAction!();
      }
    : undefined;
  toasts.push({ id, tone, title, description, actionLabel: opts?.actionLabel, onAction });
  setTimeout(() => dismissToast(id), opts?.duration ?? (tone === "danger" ? 7000 : 4000));
}

export function dismissToast(id: number) {
  const i = toasts.findIndex((t) => t.id === id);
  if (i !== -1) toasts.splice(i, 1);
}
