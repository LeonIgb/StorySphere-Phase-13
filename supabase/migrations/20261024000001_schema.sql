-- StorySphere Phase 13: schema (tables, constraints, indexes, triggers).
-- Run order: 0001 schema -> 0002 security (grants + RLS) -> 0003 functions (RPCs).
-- Targets Supabase (Postgres 15+). Uses auth.users and auth.uid() from Supabase Auth.

-- ------------------------------------------------------------------ helpers
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ------------------------------------------------------------------ profiles
-- One row per auth user. Created by the on-signup trigger (never by the client).
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  handle           text not null unique check (handle ~ '^@[a-z0-9.]{1,30}$'),
  display_name     text not null check (char_length(btrim(display_name)) between 1 and 40),
  bio              text not null default '' check (char_length(bio) <= 300),
  role             text not null default 'reader' check (role in ('reader', 'storyteller')),
  avatar_color     text not null default '#4F46E5' check (avatar_color ~ '^#[0-9A-Fa-f]{6}$'),
  avatar_url       text check (avatar_url is null or char_length(avatar_url) <= 500),
  preferred_genres text[] not null default '{}' check (cardinality(preferred_genres) <= 8),
  prefs            jsonb not null default '{}'::jsonb check (pg_column_size(prefs) <= 4096),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------ genres and tags
create table public.genres (
  id         text primary key check (id ~ '^[a-z0-9-]{2,30}$'),
  name       text not null unique,
  sort_order int  not null default 0
);

create table public.tags (
  id   bigint generated always as identity primary key,
  name text not null check (name = lower(btrim(name)) and char_length(name) between 1 and 24)
);
create unique index tags_name_key on public.tags (name);

-- ------------------------------------------------------------------ stories and chapters
create table public.stories (
  id           uuid primary key default gen_random_uuid(),
  author_id    uuid not null references public.profiles (id) on delete cascade,
  title        text not null check (char_length(btrim(title)) between 3 and 80),
  synopsis     text not null default '' check (char_length(synopsis) <= 600),
  cover_url    text check (cover_url is null or char_length(cover_url) <= 500),
  cover_color  text not null default '#312B78' check (cover_color ~ '^#[0-9A-Fa-f]{6}$'),
  genre_id     text references public.genres (id) on update cascade on delete set null,
  story_type   text not null default 'written' check (story_type in ('written', 'image', 'mixed', 'video')),
  is_mature    boolean not null default false,
  status       text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  published_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check ((status = 'published') = (published_at is not null) or status = 'archived')
);
create index stories_author_idx on public.stories (author_id);
create index stories_feed_idx   on public.stories (published_at desc) where status = 'published';
create index stories_genre_idx  on public.stories (genre_id) where status = 'published';
create trigger stories_updated before update on public.stories
  for each row execute function public.set_updated_at();

-- 5,000 words is roughly 35,000 characters; the limit is enforced here as 40,000 characters.
create table public.chapters (
  id         uuid primary key default gen_random_uuid(),
  story_id   uuid not null references public.stories (id) on delete cascade,
  position   int  not null check (position between 1 and 500),
  title      text not null check (char_length(btrim(title)) between 1 and 80),
  body       text not null default '' check (char_length(body) <= 40000),
  status     text not null default 'draft' check (status in ('draft', 'published')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (story_id, position) deferrable initially deferred,
  unique (id, story_id)
);
create trigger chapters_updated before update on public.chapters
  for each row execute function public.set_updated_at();

create table public.story_tags (
  story_id uuid   not null references public.stories (id) on delete cascade,
  tag_id   bigint not null references public.tags (id) on delete cascade,
  primary key (story_id, tag_id)
);
create index story_tags_tag_idx on public.story_tags (tag_id);

-- ------------------------------------------------------------------ social and reading
create table public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  followee_id uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index follows_followee_idx on public.follows (followee_id);

create table public.bookmarks (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  story_id   uuid not null references public.stories (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, story_id)
);
create index bookmarks_story_idx on public.bookmarks (story_id);

create table public.reading_progress (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  story_id   uuid not null references public.stories (id) on delete cascade,
  chapter_id uuid,
  position   numeric(5, 4) not null default 0 check (position between 0 and 1),
  updated_at timestamptz not null default now(),
  primary key (user_id, story_id),
  foreign key (chapter_id, story_id) references public.chapters (id, story_id) on delete cascade
);
create trigger reading_progress_updated before update on public.reading_progress
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------ engagement
create table public.story_likes (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  story_id   uuid not null references public.stories (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, story_id)
);
create index story_likes_story_idx on public.story_likes (story_id);

create table public.reviews (
  id         uuid primary key default gen_random_uuid(),
  story_id   uuid not null references public.stories (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  rating     int  not null check (rating between 1 and 5),
  body       text not null default '' check (char_length(body) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (story_id, user_id)
);
create trigger reviews_updated before update on public.reviews
  for each row execute function public.set_updated_at();

create table public.comments (
  id         uuid primary key default gen_random_uuid(),
  story_id   uuid not null references public.stories (id) on delete cascade,
  chapter_id uuid,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  parent_id  uuid,
  body       text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, story_id),
  foreign key (chapter_id, story_id) references public.chapters (id, story_id) on delete cascade,
  foreign key (parent_id, story_id) references public.comments (id, story_id) on delete cascade
);
create index comments_story_idx on public.comments (story_id, created_at);
create trigger comments_updated before update on public.comments
  for each row execute function public.set_updated_at();

-- ------------------------------------------------------------------ signup trigger
-- Creates the profile for every new auth user. The client only supplies display_name and role
-- as sign-up metadata; both are validated here, and the handle is generated server-side.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name   text;
  v_role   text;
  v_base   text;
  v_handle text;
  v_n      int := 1;
begin
  v_name := left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 40);
  if v_name = '' then
    v_name := left(coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Reader'), 40);
  end if;
  v_role := case when new.raw_user_meta_data ->> 'role' = 'storyteller' then 'storyteller' else 'reader' end;

  v_base := left(regexp_replace(lower(v_name), '[^a-z0-9]+', '.', 'g'), 20);
  v_base := btrim(v_base, '.');
  if v_base = '' then v_base := 'reader'; end if;
  v_handle := '@' || v_base;
  while exists (select 1 from public.profiles where handle = v_handle) loop
    v_n := v_n + 1;
    v_handle := '@' || v_base || v_n::text;
  end loop;

  insert into public.profiles (id, handle, display_name, role)
  values (new.id, v_handle, v_name, v_role);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------------ public read views
-- Counts per story. security_invoker makes the view obey the caller's RLS, so it only
-- counts rows the caller may see and never leaks drafts.
create view public.story_stats with (security_invoker = true) as
select s.id as story_id,
       (select count(*) from public.story_likes l where l.story_id = s.id) as like_count,
       (select count(*) from public.bookmarks b where b.story_id = s.id)   as bookmark_count,
       (select count(*) from public.reviews r where r.story_id = s.id)     as review_count,
       (select round(avg(r.rating)::numeric, 2) from public.reviews r where r.story_id = s.id) as avg_rating,
       (select count(*) from public.comments c where c.story_id = s.id)    as comment_count
from public.stories s;
