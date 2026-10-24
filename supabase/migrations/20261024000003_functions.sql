-- StorySphere Phase 13: server-side authorization. These functions run as the table owner
-- (SECURITY DEFINER) but always check auth.uid() themselves, validate their input, and pin
-- search_path. Publishing is only possible through them, because clients cannot write
-- stories.status, stories.published_at or chapters.status.

create or replace function public.publish_story(p_story_id uuid)
returns public.stories
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_story public.stories;
  v_count int;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select * into v_story from public.stories where id = p_story_id for update;
  if not found or v_story.author_id <> v_uid then
    raise exception 'not_found_or_not_owner' using errcode = '42501';
  end if;
  if char_length(btrim(v_story.title)) < 3 then
    raise exception 'title_too_short' using errcode = '23514';
  end if;
  if char_length(btrim(v_story.synopsis)) < 10 then
    raise exception 'synopsis_too_short' using errcode = '23514';
  end if;
  select count(*) into v_count from public.chapters
    where story_id = p_story_id and char_length(btrim(body)) > 0;
  if v_count = 0 and v_story.story_type = 'written' then
    raise exception 'needs_a_chapter_with_text' using errcode = '23514';
  end if;

  update public.chapters set status = 'published'
    where story_id = p_story_id and status = 'draft' and char_length(btrim(body)) > 0;
  update public.stories
    set status = 'published', published_at = coalesce(published_at, now())
    where id = p_story_id
    returning * into v_story;
  return v_story;
end;
$$;

create or replace function public.publish_chapter(p_chapter_id uuid)
returns public.chapters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_ch  public.chapters;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select c.* into v_ch from public.chapters c
    join public.stories s on s.id = c.story_id
    where c.id = p_chapter_id and s.author_id = v_uid and s.status = 'published'
    for update of c;
  if not found then
    raise exception 'not_found_or_not_owner' using errcode = '42501';
  end if;
  if char_length(btrim(v_ch.body)) = 0 then
    raise exception 'chapter_is_empty' using errcode = '23514';
  end if;
  update public.chapters set status = 'published' where id = p_chapter_id returning * into v_ch;
  return v_ch;
end;
$$;

create or replace function public.unpublish_story(p_story_id uuid)
returns public.stories
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_story public.stories;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  update public.stories set status = 'draft', published_at = null
    where id = p_story_id and author_id = v_uid
    returning * into v_story;
  if not found then
    raise exception 'not_found_or_not_owner' using errcode = '42501';
  end if;
  return v_story;
end;
$$;

-- Replaces a story's tags (max 8, 1-24 characters each, lower-cased). Owner only.
create or replace function public.set_story_tags(p_story_id uuid, p_tags text[])
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_clean text[];
  v_name  text;
  v_id    bigint;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.stories where id = p_story_id and author_id = v_uid) then
    raise exception 'not_found_or_not_owner' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct t), '{}') into v_clean
    from (select lower(btrim(x)) as t from unnest(coalesce(p_tags, '{}')) as x) q
    where char_length(t) between 1 and 24;
  if cardinality(v_clean) > 8 then
    raise exception 'too_many_tags' using errcode = '23514';
  end if;

  delete from public.story_tags where story_id = p_story_id;
  foreach v_name in array v_clean loop
    insert into public.tags (name) values (v_name)
      on conflict (name) do nothing;
    select id into v_id from public.tags where name = v_name;
    insert into public.story_tags (story_id, tag_id) values (p_story_id, v_id);
  end loop;
  return v_clean;
end;
$$;

-- Callable by signed-in users only.
revoke all on function public.publish_story(uuid), public.publish_chapter(uuid),
  public.unpublish_story(uuid), public.set_story_tags(uuid, text[]) from public, anon;
grant execute on function public.publish_story(uuid), public.publish_chapter(uuid),
  public.unpublish_story(uuid), public.set_story_tags(uuid, text[]) to authenticated;

-- The signup trigger function is never callable through the API.
revoke all on function public.handle_new_user() from public, anon, authenticated;
