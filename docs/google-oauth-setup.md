# Google OAuth client setup (~5 minutes)

Hey Pigeon is client-only: you bring your own Google OAuth client ID. Nothing is
shared, nothing runs on a server, and Google never sees a third party.

## Steps

1. Go to <https://console.cloud.google.com/> and create a project
   (e.g. `heypigeon`). Any existing personal project works too.
2. **Enable the Gmail API**: APIs & Services → Library → search "Gmail API" → Enable.
3. **Configure the consent screen**: APIs & Services → OAuth consent screen
   - User type: **External** (the only choice without a Workspace org).
   - App name `Hey Pigeon`, your email for the contact fields. Save through the
     defaults — no scopes need to be added here for testing.
   - Under **Audience → Test users**: add your own Gmail address(es) — both
     accounts you plan to connect. **Without this, login fails.**
4. **Create the client**: APIs & Services → Credentials → Create credentials →
   OAuth client ID
   - Application type: **Desktop app**
   - Name: `heypigeon-desktop`
5. Copy the **Client ID** (`…apps.googleusercontent.com`) and the
   **Client secret**.

## Hand the values to the app

Put them in `~/.config/heypigeon/oauth.json` (create the folder if needed):

```json
{
  "client_id": "xxxxxxxx.apps.googleusercontent.com",
  "client_secret": "GOCSPX-…"
}
```

Never commit these. The file lives outside the repo on purpose.

> A Desktop-app "client secret" is not actually secret (Google's own docs say
> so) — it just must stay out of public repos.

## Known caveats while the app is in "Testing" mode

- **Refresh tokens expire after 7 days** in Testing mode. Re-login weekly, or
  push the consent screen to "In production" (self-owned apps with
  `gmail.modify` will show an "unverified app" warning you can click through —
  fine for personal use).
- The consent screen will say "Google hasn't verified this app" — expected;
  click *Advanced → Go to Hey Pigeon (unsafe)*. It's your own client.

## Scope used

- `https://www.googleapis.com/auth/gmail.modify` — read + label changes
  (archive needs it). Compose/send (M3) will add `gmail.send`.
