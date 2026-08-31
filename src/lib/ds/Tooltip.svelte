<script lang="ts">
  import type { Snippet } from "svelte";

  let {
    label,
    side = "top",
    children,
  }: {
    label: string;
    side?: "top" | "bottom";
    children: Snippet;
  } = $props();
</script>

<span class="wrap">
  {@render children()}
  <span class="tip {side}">{label}</span>
</span>

<style>
  .wrap {
    position: relative;
    display: inline-flex;
  }
  .tip {
    display: none;
    position: absolute;
    left: 50%;
    white-space: nowrap;
    padding: 6px 10px;
    background: var(--surface-inverse);
    color: var(--text-inverse);
    font-family: var(--font-body);
    font-size: var(--text-caption);
    z-index: 10;
  }
  .tip.top {
    bottom: 100%;
    transform: translate(-50%, -6px);
  }
  .tip.bottom {
    top: 100%;
    transform: translate(-50%, 6px);
  }
  .wrap:hover > .tip {
    display: block;
  }
</style>
