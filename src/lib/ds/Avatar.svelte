<script lang="ts">
  // Image avatar with a fallback chain: explicit photo → gravatar → sender
  // domain favicon (brand logos) → initials. Gmail's API exposes no sender
  // photos, so this is the best serverless coverage available.
  // ponytail: leaks sender-address hash to gravatar.com and sender domain to
  // gstatic.com per row; gate behind the remote-image privacy setting in M3.
  let {
    src,
    email,
    name,
    size = 26,
    bg = "var(--surface-sunken)",
    fg = "var(--text-secondary)",
    fontWeight = 600,
  }: {
    /** Explicit photo URL (e.g. Google profile picture); wins over lookups. */
    src?: string;
    email?: string;
    name: string;
    size?: number;
    bg?: string;
    fg?: string;
    fontWeight?: number;
  } = $props();

  // Domains where a favicon would be meaningless (personal mail providers).
  const FREEMAIL = new Set([
    "gmail.com", "googlemail.com", "yahoo.com", "hotmail.com", "outlook.com",
    "live.com", "icloud.com", "me.com", "proton.me", "protonmail.com",
    "gmx.net", "gmx.de", "web.de", "aol.com", "example.com", "heypigeon.app",
  ]);

  let sources: string[] = $state([]);
  let phase = $state(0);

  const initials = $derived(
    name
      .split(/[@.\s]/)
      .filter(Boolean)
      .slice(0, 2)
      .map((w) => w[0].toUpperCase())
      .join(""),
  );

  $effect(() => {
    phase = 0;
    const list: string[] = [];
    if (src) list.push(src);
    const addr = email?.trim().toLowerCase();
    const domain = addr?.split("@")[1];
    if (domain && !FREEMAIL.has(domain)) {
      // 404s when the domain has no known icon → chain advances to initials.
      list.push(
        `https://t1.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&url=https://${domain}&size=${size * 2}`,
      );
    }
    sources = list;
    if (!addr) return;
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(addr)).then((buf) => {
      const hex = Array.from(new Uint8Array(buf))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
      // Gravatar outranks the domain favicon: personal photo beats brand logo.
      const at = src ? 1 : 0;
      sources = [...sources.slice(0, at), `https://gravatar.com/avatar/${hex}?d=404&s=${size * 2}`, ...sources.slice(at)];
    });
  });
</script>

{#if phase < sources.length}
  <img
    src={sources[phase]}
    alt={name}
    width={size}
    height={size}
    class="avatar-img"
    onerror={() => (phase = phase + 1)}
  />
{:else}
  <span
    class="avatar-initials"
    style:width="{size}px"
    style:height="{size}px"
    style:background={bg}
    style:color={fg}
    style:font-size="{Math.max(10, Math.round(size * 0.4))}px"
    style:font-weight={fontWeight}>{initials}</span
  >
{/if}

<style>
  .avatar-img {
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
    display: block;
    background: var(--surface-sunken);
  }
  .avatar-initials {
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-body);
    flex-shrink: 0;
  }
</style>
