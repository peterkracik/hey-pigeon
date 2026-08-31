<script lang="ts">
  let {
    value = $bindable(""),
    options = [],
    size = "md",
    disabled = false,
    onchange,
  }: {
    value?: string;
    options?: { value: string; label: string }[];
    size?: "sm" | "md" | "lg";
    disabled?: boolean;
    onchange?: (value: string) => void;
  } = $props();

  const height = $derived(size === "sm" ? 30 : size === "lg" ? 42 : 36);
</script>

<select bind:value {disabled} style:height="{height}px" onchange={() => onchange?.(value)}>
  {#each options as o (o.value)}
    <option value={o.value}>{o.label}</option>
  {/each}
</select>

<style>
  select {
    padding: 0 22px 0 2px;
    border-radius: 0;
    border: none;
    border-bottom: 1px solid var(--border-default);
    background: transparent;
    color: var(--text-primary);
    font-family: var(--font-body);
    font-size: var(--text-body);
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6'%3E%3Cpath d='M0 0l5 6 5-6z' fill='%2375787F'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 2px center;
    cursor: pointer;
  }
  select:disabled {
    cursor: not-allowed;
    opacity: 0.5;
  }
</style>
