<script lang="ts">
  // Image avatar with a fallback chain: explicit photo → Google contact photo
  // (People API, people you've corresponded with) → gravatar → sender-domain
  // favicon (brand logos) → initials.
  // ponytail: leaks sender-address hash to gravatar.com and sender domain to
  // duckduckgo.com per row; gate behind the remote-image privacy setting in M3.
  import { lookupAvatar } from "../ipc";

  let {
    src,
    email,
    accountId,
    name,
    size = 26,
    bg = "var(--surface-sunken)",
    fg = "var(--text-secondary)",
    fontWeight = 600,
  }: {
    /** Explicit photo URL (e.g. Google profile picture); wins over lookups. */
    src?: string;
    email?: string;
    /** Enables the People-API contact-photo lookup for this sender. */
    accountId?: string;
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

  // Priority slots; the visible list is derived so late async arrivals keep
  // their intended rank instead of appending at the end.
  let contactUrl: string | null = $state(null);
  let gravatarUrl: string | null = $state(null);

  const slots = $derived.by(() => {
    const addr = email?.trim().toLowerCase();
    const domain = addr?.split("@")[1];
    const favicon =
      domain && !FREEMAIL.has(domain)
        ? `https://icons.duckduckgo.com/ip3/${domain}.ico`
        : null;
    return [src ?? null, contactUrl, gravatarUrl, favicon].filter((s): s is string => Boolean(s));
  });

  $effect(() => {
    phase = 0;
    contactUrl = null;
    gravatarUrl = null;
    const addr = email?.trim().toLowerCase();
    if (!addr) {
      sources = slots;
      return;
    }
    if (accountId) {
      lookupAvatar(accountId, addr).then((u) => (contactUrl = u));
    }
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(addr)).then((buf) => {
      const hex = Array.from(new Uint8Array(buf))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
      gravatarUrl = `https://gravatar.com/avatar/${hex}?d=404&s=${size * 2}`;
    });
  });

  $effect(() => {
    sources = slots;
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
