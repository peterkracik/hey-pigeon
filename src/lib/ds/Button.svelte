<script lang="ts">
  import type { Snippet } from "svelte";

  let {
    variant = "primary",
    size = "md",
    disabled = false,
    onclick,
    type = "button",
    children,
  }: {
    variant?: "primary" | "secondary" | "ghost" | "danger";
    size?: "sm" | "md" | "lg";
    disabled?: boolean;
    onclick?: (ev: MouseEvent) => void;
    type?: "button" | "submit";
    children: Snippet;
  } = $props();
</script>

<button {type} {disabled} onclick={disabled ? undefined : onclick} class="btn {variant} {size}">
  {@render children()}
</button>

<style>
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    justify-content: center;
    font-family: var(--font-body);
    font-weight: 600;
    line-height: 1;
    border-radius: var(--radius-sm);
    border: none;
    cursor: pointer;
    transition:
      background var(--duration-fast) var(--ease-standard),
      color var(--duration-fast) var(--ease-standard),
      opacity var(--duration-fast);
  }
  .btn:disabled {
    cursor: not-allowed;
    opacity: 0.45;
  }
  .sm {
    padding: 6px 12px;
    font-size: var(--text-small);
    height: 32px;
  }
  .md {
    padding: 9px 16px;
    font-size: var(--text-body);
    height: 40px;
  }
  .lg {
    padding: 12px 20px;
    font-size: var(--text-body-l);
    height: 48px;
  }
  .primary {
    background: var(--accent-primary);
    color: var(--text-inverse);
  }
  .primary:hover:not(:disabled) {
    background: var(--navy-800);
  }
  .secondary {
    background: transparent;
    color: var(--text-primary);
  }
  .ghost {
    background: transparent;
    color: var(--text-secondary);
  }
  .ghost:hover:not(:disabled),
  .secondary:hover:not(:disabled) {
    color: var(--text-primary);
  }
  .danger {
    background: transparent;
    color: var(--state-danger);
  }
</style>
