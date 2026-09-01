<script lang="ts">
  import type { Snippet } from "svelte";

  let {
    size = "md",
    active = false,
    disabled = false,
    onclick,
    label,
    children,
  }: {
    size?: "sm" | "md" | "lg";
    active?: boolean;
    disabled?: boolean;
    onclick?: (ev: MouseEvent) => void;
    label: string;
    children: Snippet;
  } = $props();

  const dims = { sm: 28, md: 36, lg: 44 };
</script>

<button
  aria-label={label}
  {disabled}
  onclick={disabled ? undefined : onclick}
  class="icon-btn"
  class:active
  style:width="{dims[size]}px"
  style:height="{dims[size]}px"
>
  {@render children()}
</button>

<style>
  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
    background: transparent;
    border: 1px solid transparent;
    color: var(--text-tertiary);
    cursor: pointer;
    transition: color var(--duration-fast) var(--ease-standard);
    padding: 0;
  }
  .icon-btn:hover:not(:disabled),
  .icon-btn.active {
    color: var(--text-primary);
  }
  .icon-btn:disabled {
    cursor: not-allowed;
    opacity: 0.4;
  }
</style>
