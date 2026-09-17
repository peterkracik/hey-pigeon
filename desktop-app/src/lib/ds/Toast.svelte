<script lang="ts">
  let {
    tone = "info",
    title,
    description,
    actionLabel,
    onAction,
    onClose,
  }: {
    tone?: "success" | "warning" | "danger" | "info";
    title: string;
    description?: string;
    actionLabel?: string;
    onAction?: () => void;
    onClose?: () => void;
  } = $props();

  const ICONS = { success: "✓", warning: "!", danger: "✕", info: "i" } as const;
  const TONES = {
    success: "var(--tag-mint-fg)",
    warning: "var(--tag-amber-fg)",
    danger: "var(--tag-coral-fg)",
    info: "var(--pink)",
  } as const;
</script>

<div class="toast" role="status">
  <span class="icon" style:background={TONES[tone]}>{ICONS[tone]}</span>
  <div class="body">
    <div class="title">{title}</div>
    {#if description}
      <div class="desc">{description}</div>
    {/if}
    {#if actionLabel && onAction}
      <button class="action" onclick={onAction}>{actionLabel}</button>
    {/if}
  </div>
  {#if onClose}
    <button class="close" aria-label="Dismiss" onclick={onClose}>
      <svg width="12" height="12" viewBox="0 0 10 10">
        <path d="M1 1l8 8M9 1l-8 8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
      </svg>
    </button>
  {/if}
</div>

<style>
  .toast {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 13px 16px;
    width: 320px;
    box-sizing: border-box;
    background: var(--surface-inverse);
    border-radius: var(--radius-xl);
    font-family: var(--font-body);
    box-shadow: var(--shadow-lg);
  }
  .icon {
    width: 20px;
    height: 20px;
    border-radius: 50%;
    color: var(--text-inverse);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    flex-shrink: 0;
  }
  .body {
    flex: 1;
    min-width: 0;
  }
  .title {
    font-size: var(--text-small);
    font-weight: 700;
    color: var(--text-inverse);
  }
  .desc {
    font-size: var(--text-small);
    color: var(--navy-300);
    margin-top: 2px;
    overflow-wrap: break-word;
  }
  .action {
    border: none;
    background: var(--surface-card);
    cursor: pointer;
    color: var(--text-primary);
    font-family: var(--font-body);
    font-size: 12px;
    font-weight: 700;
    padding: 5px 12px;
    margin-top: 8px;
    border-radius: var(--radius-pill);
  }
  .action:hover {
    background: var(--navy-200);
  }
  .close {
    border: none;
    background: transparent;
    cursor: pointer;
    color: var(--navy-400);
    padding: 0;
  }
</style>
