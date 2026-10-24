# StorySphere backend setup (Phase 13)

**Status: NOT CONNECTED.** This repository contains the backend schema, security rules, Edge Function
and app code, but no Supabase project has been created or linked, so nothing here has been run against
a real project. The app shows "Local demo mode" until you complete the steps below, and shows
"Connected and verified" only after its own live check passes.

## Why Supabase
The data is relational (stories -> chapters, many-to-many tags, follows, bookmarks, likes, reviews,
comments), and Postgres foreign keys, constraints and Row Level Security (RLS) express that and the
access rules declaratively. `@supabase/supabase-js` is pure JavaScript, works in Expo and Snack, and
keeps the session in AsyncStorage. Firebase/Firestore would need denormalised data and separate
security-rules code with weaker integrity guarantees for this model.

## 1. Create the project
1. Create a free project at https://supabase.com/dashboard (choose a region near your readers).
2. Save the database password in a password manager. It is never used by the app.

## 2. Install the schema
Open **SQL Editor** and run these files, in order, each as one query:
1. `supabase/migrations/20261024000001_schema.sql`
2. `supabase/migrations/20261024000002_security.sql`
3. `supabase/migrations/20261024000003_functions.sql`
4. `supabase/seed.sql` (genres only)

Or with the Supabase CLI: `supabase link --project-ref <ref>` then `supabase db push`, and run `seed.sql`.

## 3. Configure sign-up
**Authentication > Providers > Email**: keep it enabled. Decide on **Confirm email**:
- On (recommended for production): new users must click a link; the app shows "check your email".
- Off: sign-up signs in immediately (handy for testing).

**Authentication > URL Configuration**: set the Site URL / redirect URLs for your app.
**Authentication > Rate limits** and **Password strength**: review the defaults before launch.

## 4. Give the app its two PUBLIC values
**Project Settings > API**: copy the *Project URL* and the *anon / publishable key*.

- Local Expo project: copy `.env.example` to `.env` and set
  `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY`. Restart with `npx expo start -c`.
- Expo Snack (no .env): paste them into `SNACK_URL` / `SNACK_ANON_KEY` in `src/config/backendConfig.js`.

**Never** put the `service_role` key, an `sb_secret_...` key, the database password or the JWT secret
in the app, in `.env` files that are committed, or in Snack. The app refuses to start the backend if the
key's role is anything other than `anon`, but the only real protection is not pasting it.

## 5. (Optional) account deletion Edge Function
Needed only for "Delete account" on online accounts (deleting an auth user requires a privileged key,
which exists only on the server).
```
supabase functions deploy delete-account
```
Supabase injects `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions
automatically; do not set the service key anywhere else. **This function is unverified** (no project or
Deno runtime was available when it was written). Test it with a throw-away account.

## 6. Verify the connection
Run the app, sign in or open **Profile > Settings & privacy > Online service**, tap **Check connection**.
It makes two real requests (Auth health and a read of `genres`). Only "Connected and verified" means
the project, key and schema work. Other results: "Can't reach the server", "The key was rejected",
"Connected, schema not installed".

## What is in the database
`profiles, genres, tags, stories, chapters, story_tags, follows, bookmarks, reading_progress,
story_likes, reviews, comments` and the view `story_stats`, with constraints (e.g. chapters up to
40,000 characters, one review per reader, no self-follow), indexes, `updated_at` triggers and a
signup trigger that creates the profile.

## Access rules (enforced by the database, not the app)
- Everything has RLS on. `anon` can only read public data; `authenticated` can write only as itself
  (`auth.uid()`), never as another user.
- Drafts and archived stories, and unpublished chapters, are visible only to their author.
- Clients cannot write `stories.status`, `published_at`, `chapters.status`, `author_id` or
  `profiles.id` (column privileges). Publishing is only possible through `publish_story`,
  `publish_chapter`, `unpublish_story` and tags through `set_story_tags`, which check ownership and
  content rules server-side.
- Bookmarks and reading progress are private. Follows, likes, reviews and comments are public.
  You cannot review your own story. Authors can delete comments on their own stories.
- Profiles are created only by the signup trigger from validated metadata; handles are generated
  server-side.

## What is connected in the app (and what is not)
| Area | Status |
| --- | --- |
| Registration, login, logout, session persistence and refresh | Wired (online mode) |
| Profile record and preferences | Wired: saved to the server, local copy kept as offline cache |
| Delete account | Wired through the Edge Function (unverified) |
| Backend status / connection check, error and network handling | Wired |
| Stories, chapters, genres, tags, follows, bookmarks, progress, likes, reviews, comments | **Database + client repositories written; NOT yet wired into the screens.** These still use local prototype data. |
| Media files (images, audio, video), purchases, messages, notifications | Not part of Phase 13; still local/demo |

## Tests included
`supabase/tests/` runs the three migrations and the seed in a real Postgres with a stand-in for
Supabase's `auth` schema, then checks 72 access-control and constraint behaviours (for example: another
user cannot read a draft, edit someone else's profile or comment, set `status`, or publish).
```
PGHOST=localhost PGUSER=postgres python3 supabase/tests/rls_test.py
```
These tests prove the SQL rules on Postgres. They do not prove Supabase-hosted behaviour (PostgREST,
Auth, Edge Functions).
