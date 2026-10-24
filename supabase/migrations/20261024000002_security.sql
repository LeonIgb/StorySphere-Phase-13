-- StorySphere Phase 13: access control. Table grants (coarse), column grants (fine) and Row Level
-- Security policies (per row). The client only ever holds the anon/publishable key, so these rules
-- are the real authorization layer. Nothing here trusts a value the client sends about who it is:
-- identity always comes from auth.uid(), i.e. the verified JWT.

-- Start from nothing. Supabase's default privileges grant broad access to anon/authenticated.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

alter table public.profiles         enable row level security;
alter table public.genres           enable row level security;
alter table public.tags             enable row level security;
alter table public.stories          enable row level security;
alter table public.chapters         enable row level security;
alter table public.story_tags       enable row level security;
alter table public.follows          enable row level security;
alter table public.bookmarks        enable row level security;
alter table public.reading_progress enable row level security;
alter table public.story_likes      enable row level security;
alter table public.reviews          enable row level security;
alter table public.comments         enable row level security;

-- ------------------------------------------------------------------ grants
-- Public reads (RLS still filters drafts).
grant usage on schema public to anon, authenticated;
grant select on public.genres, public.tags, public.profiles, public.stories, public.chapters,
                public.story_tags, public.reviews, public.comments, public.story_likes,
                public.follows, public.story_stats to anon, authenticated;
-- Private reads.
grant select on public.bookmarks, public.reading_progress to authenticated;

-- Writes, column by column. Columns that are not listed (profiles.id, stories.author_id,
-- stories.status, stories.published_at, chapters.status, timestamps) can never be set by a client.
grant update (handle, display_name, bio, role, avatar_color, avatar_url, preferred_genres, prefs)
  on public.profiles to authenticated;
grant insert (author_id, title, synopsis, cover_url, cover_color, genre_id, story_type, is_mature)
  on public.stories to authenticated;
grant update (title, synopsis, cover_url, cover_color, genre_id, story_type, is_mature)
  on public.stories to authenticated;
grant delete on public.stories to authenticated;
grant insert (story_id, position, title, body) on public.chapters to authenticated;
grant update (position, title, body)           on public.chapters to authenticated;
grant delete on public.chapters to authenticated;
grant insert (follower_id, followee_id) on public.follows        to authenticated;
grant delete                            on public.follows        to authenticated;
grant insert (user_id, story_id)        on public.bookmarks      to authenticated;
grant delete                            on public.bookmarks      to authenticated;
grant insert (user_id, story_id, chapter_id, position) on public.reading_progress to authenticated;
grant update (chapter_id, position)                    on public.reading_progress to authenticated;
grant delete                                           on public.reading_progress to authenticated;
grant insert (user_id, story_id)        on public.story_likes    to authenticated;
grant delete                            on public.story_likes    to authenticated;
grant insert (story_id, user_id, rating, body) on public.reviews to authenticated;
grant update (rating, body)                    on public.reviews to authenticated;
grant delete                                   on public.reviews to authenticated;
grant insert (story_id, chapter_id, user_id, parent_id, body) on public.comments to authenticated;
grant update (body)                                           on public.comments to authenticated;
grant delete                                                  on public.comments to authenticated;
-- story_tags and tags are written only by the set_story_tags() function.

-- ------------------------------------------------------------------ policies
-- profiles: public read; you can edit only your own row; rows are created by the signup trigger.
create policy profiles_read   on public.profiles for select to anon, authenticated using (true);
create policy profiles_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy genres_read on public.genres for select to anon, authenticated using (true);
create policy tags_read   on public.tags   for select to anon, authenticated using (true);

-- stories: published stories are public; drafts and archived stories only to their author.
create policy stories_read on public.stories for select to anon, authenticated
  using (status = 'published' or author_id = (select auth.uid()));
create policy stories_insert on public.stories for insert to authenticated
  with check (author_id = (select auth.uid()) and status = 'draft');
create policy stories_update on public.stories for update to authenticated
  using (author_id = (select auth.uid())) with check (author_id = (select auth.uid()));
create policy stories_delete on public.stories for delete to authenticated
  using (author_id = (select auth.uid()));

-- chapters: a published chapter of a published story is public; everything else only to the author.
-- (The subqueries on stories are themselves filtered by stories_read.)
create policy chapters_read on public.chapters for select to anon, authenticated
  using (
    exists (select 1 from public.stories s where s.id = chapters.story_id and s.author_id = (select auth.uid()))
    or (chapters.status = 'published'
        and exists (select 1 from public.stories s where s.id = chapters.story_id and s.status = 'published'))
  );
create policy chapters_insert on public.chapters for insert to authenticated
  with check (status = 'draft'
              and exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())));
create policy chapters_update on public.chapters for update to authenticated
  using (exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())))
  with check (exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())));
create policy chapters_delete on public.chapters for delete to authenticated
  using (exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())));

-- story_tags: readable wherever the story is visible; written only through set_story_tags().
create policy story_tags_read on public.story_tags for select to anon, authenticated
  using (exists (select 1 from public.stories s where s.id = story_tags.story_id));

-- follows: the social graph is public; you can only follow or unfollow as yourself.
create policy follows_read   on public.follows for select to anon, authenticated using (true);
create policy follows_insert on public.follows for insert to authenticated
  with check (follower_id = (select auth.uid()));
create policy follows_delete on public.follows for delete to authenticated
  using (follower_id = (select auth.uid()));

-- bookmarks and reading progress: private to their owner.
create policy bookmarks_read   on public.bookmarks for select to authenticated using (user_id = (select auth.uid()));
create policy bookmarks_insert on public.bookmarks for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.stories s where s.id = story_id));
create policy bookmarks_delete on public.bookmarks for delete to authenticated using (user_id = (select auth.uid()));

create policy progress_read   on public.reading_progress for select to authenticated using (user_id = (select auth.uid()));
create policy progress_insert on public.reading_progress for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.stories s where s.id = story_id and s.status = 'published'));
create policy progress_update on public.reading_progress for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy progress_delete on public.reading_progress for delete to authenticated using (user_id = (select auth.uid()));

-- likes: counts are public; you like as yourself, and only published stories.
create policy likes_read   on public.story_likes for select to anon, authenticated
  using (exists (select 1 from public.stories s where s.id = story_likes.story_id));
create policy likes_insert on public.story_likes for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.stories s where s.id = story_id and s.status = 'published'));
create policy likes_delete on public.story_likes for delete to authenticated using (user_id = (select auth.uid()));

-- reviews: public on visible stories; one per reader; you cannot review your own story.
create policy reviews_read on public.reviews for select to anon, authenticated
  using (exists (select 1 from public.stories s where s.id = reviews.story_id));
create policy reviews_insert on public.reviews for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.stories s
                          where s.id = story_id and s.status = 'published' and s.author_id <> (select auth.uid())));
create policy reviews_update on public.reviews for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy reviews_delete on public.reviews for delete to authenticated using (user_id = (select auth.uid()));

-- comments: public on visible stories; you comment as yourself; edit your own; delete your own,
-- or any comment on your own story (moderation by the author).
create policy comments_read on public.comments for select to anon, authenticated
  using (exists (select 1 from public.stories s where s.id = comments.story_id));
create policy comments_insert on public.comments for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.stories s where s.id = story_id and s.status = 'published'));
create policy comments_update on public.comments for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy comments_delete on public.comments for delete to authenticated
  using (user_id = (select auth.uid())
         or exists (select 1 from public.stories s where s.id = story_id and s.author_id = (select auth.uid())));
