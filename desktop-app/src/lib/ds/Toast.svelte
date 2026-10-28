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
      <div class="desc" title={description}>{description}</div>
    {/if}
  </div>
  {#if actionLabel && onAction}
    <button class="action" onclick={onAction}>{actionLabel}</button>
  {/if}
  {#if onClose}
    <button class="close" aria-label="Dismiss" onclick={onClose}>
      <svg width="12" height="12" viewBox="0 0 10 10">
        <path d="M1 1l8 8M9 1l-8 8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" />
      </svg>
    </button>
  {/if}
</div>

<style>
  /* Compact single-row layout: several stacked toasts (e.g. archiving a few
     emails in a row) must not eat the inbox. Description is clamped to one
     line; hover shows the full text via the title attribute. */
  .toast {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px 8px 12px;
    width: 340px;
    box-sizing: border-box;
    background: var(--surface-inverse);
    border-radius: var(--radius-lg);
    font-family: var(--font-body);
    box-shadow: var(--shadow-lg);
  }
  .icon {
    width: 18px;
    height: 18px;
    border-radius: 50%;
    color: var(--text-inverse);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 10px;
    flex-shrink: 0;
  }
  .body {
    flex: 1;
    min-width: 0;
  }
  .title {
    font-size: 12px;
    font-weight: 700;
    line-height: 1.3;
    color: var(--text-inverse);
  }
  .desc {
    font-size: 12px;
    line-height: 1.3;
    color: var(--navy-300);
    margin-top: 1px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .action {
    border: none;
    background: var(--surface-card);
    cursor: pointer;
    color: var(--text-primary);
    font-family: var(--font-body);
    font-size: 11px;
    font-weight: 700;
    padding: 4px 10px;
    border-radius: var(--radius-pill);
    flex-shrink: 0;
  }
  .action:hover {
    background: var(--navy-200);
  }
  .close {
    border: none;
    background: transparent;
    cursor: pointer;
    color: var(--navy-400);
    padding: 4px;
    margin: -4px;
    display: flex;
    flex-shrink: 0;
  }
</style>
