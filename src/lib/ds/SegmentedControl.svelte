<script lang="ts">
  import Icon from "./Icon.svelte";

  export interface SegmentOption {
    value: string;
    /** Optional text label — icon-only segments omit it. */
    label?: string;
    /** Optional icon path (24×24 stroke path, same as Icon). */
    d?: string;
    /** Fill the icon solid (e.g. a status dot) instead of stroking it. */
    filled?: boolean;
    /** Tooltip; falls back to label. Give one to every icon-only segment. */
    title?: string;
  }

  let {
    options,
    value,
    onchange,
    size = "md",
  }: {
    options: SegmentOption[];
    value: string;
    onchange?: (value: string) => void;
    size?: "sm" | "md";
  } = $props();
</script>

<div class="seg" role="radiogroup">
  {#each options as o (o.value)}
    <button
      class="seg-btn {size}"
      class:active={o.value === value}
      role="radio"
      aria-checked={o.value === value}
      aria-label={o.title ?? o.label ?? o.value}
      title={o.title ?? o.label}
      onclick={() => onchange?.(o.value)}
    >
      {#if o.d}
        <Icon d={o.d} size={size === "sm" ? 14 : 16} fill={o.filled ? "currentColor" : "none"} />
      {/if}
      {#if o.label}<span class="seg-label">{o.label}</span>{/if}
    </button>
  {/each}
</div>

<style>
  .seg {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 3px;
    background: var(--surface-card);
    border: 1px solid var(--border-default);
    border-radius: var(--radius-pill);
    box-sizing: border-box;
    /* Matches IconButton size="sm" (28px) so a control sitting next to icon
       buttons — e.g. the topbar — lines up on the same row. */
    height: 28px;
  }
  .seg-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    box-sizing: border-box;
    /* Fixed height + flex centering, not padding + the font's line box —
       a text segment's line-height must never make the pill taller than an
       icon-only segment next to it. */
    height: 100%;
    border: none;
    background: none;
    cursor: pointer;
    color: var(--text-secondary);
    border-radius: var(--radius-pill);
    font-family: var(--font-body);
    font-weight: 600;
    line-height: 1;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard);
  }
  .seg-btn.md {
    padding: 0 13px;
    font-size: 13px;
  }
  .seg-btn.sm {
    padding: 0 10px;
    font-size: 12px;
  }
  .seg-btn:hover:not(.active) {
    color: var(--text-primary);
    background: var(--surface-hover);
  }
  .seg-btn.active {
    background: var(--surface-inverse);
    color: var(--text-inverse);
  }
</style>
