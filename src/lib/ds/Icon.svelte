<script lang="ts">
  let {
    d,
    size = 15,
    strokeWidth = 1.6,
    fill = "none",
    stroke = "currentColor",
  }: {
    d: string;
    size?: number;
    strokeWidth?: number;
    fill?: string;
    stroke?: string;
  } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" {fill}>
  <path {d} {stroke} stroke-width={strokeWidth} stroke-linecap="round" stroke-linejoin="round" />
</svg>
