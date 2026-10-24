import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'run.py')).read())
A=mk('Zara Ade','storyteller'); B=mk('Bola Reader'); C=mk('Chi')
# --- signup trigger
r=sh(DB,f"select handle||'|'||role||'|'||display_name from profiles where id='{A}'"); print('profile',r.stdout.strip())
ok('profile created by trigger with generated handle', r, True); assert r.stdout.strip()=='@zara.ade|storyteller|Zara Ade', r.stdout
dup=mk('Zara Ade'); r=sh(DB,f"select handle from profiles where id='{dup}'"); assert r.stdout.strip()=='@zara.ade2', r.stdout; print('PASS duplicate handle gets suffix')
evil=str(uuid.uuid4()); sh(DB,f"insert into auth.users(id,email,raw_user_meta_data) values ('{evil}','e@x.io','{{\"display_name\":\"x\",\"role\":\"admin\"}}')")
r=sh(DB,f"select role from profiles where id='{evil}'"); assert r.stdout.strip()=='reader'; print('PASS unknown role in metadata becomes reader')
# --- profiles
ok('user can edit own profile', as_(A,f"update profiles set bio='hi' where id='{A}'"))
r=as_(B,f"update profiles set bio='pwn' where id='{A}'; select 1/(case when (select bio from profiles where id='{A}')='pwn' then 0 else 1 end)"); ok("cannot edit someone else's profile (0 rows)", r)
ok('cannot change profile id (column grant)', as_(A,f"update profiles set id=gen_random_uuid() where id='{A}'"), False, 'permission denied')
ok('cannot insert a profile directly', as_(B,f"insert into profiles(id,handle,display_name) values (gen_random_uuid(),'@x','x')"), False, 'permission denied')
ok('anon can read profiles', as_(None,"select count(*) from profiles",'anon'))
ok('bad handle rejected by constraint', as_(A,f"update profiles set handle='nope' where id='{A}'"), False, 'check constraint')
# --- stories
r=as_(A,"insert into stories(author_id,title,synopsis,genre_id) values ('%s','Moon Harbor','A lighthouse keeper finds a door.','fantasy') returning id"%A)
ok('author creates draft story',r)
S1=sh(DB,"select id from stories where title='Moon Harbor'").stdout.strip()
ok('cannot create story as someone else', as_(B,f"insert into stories(author_id,title) values ('{A}','Fake title')"), False, 'row-level security')
ok('cannot insert story directly as published (column grant)', as_(A,f"insert into stories(author_id,title,status) values ('{A}','Sneaky','published')"), False, 'permission denied')
ok('author cannot set status via update', as_(A,f"update stories set status='published' where id='{S1}'"), False, 'permission denied')
ok('author cannot reassign author_id', as_(A,f"update stories set author_id='{B}' where id='{S1}'"), False, 'permission denied')
r=as_(B,f"select count(*) from stories where id='{S1}'"); 
c=subprocess.run(P+['-d',DB,'-At','-c',f"begin; set local role authenticated; select set_config('request.jwt.claim.sub','{B}',true); select count(*) from stories where id='{S1}'; commit;"],capture_output=True,text=True).stdout.split()
print('PASS' if c[-1]=='0' else 'FAIL','other user cannot see draft story', c); fails+= c[-1]!='0'
c=subprocess.run(P+['-d',DB,'-At','-c',f"begin; set local role anon; select count(*) from stories where id='{S1}'; commit;"],capture_output=True,text=True).stdout.split()
print('PASS' if c[-1]=='0' else 'FAIL','anon cannot see draft story'); fails+= c[-1]!='0'
# chapters
ok('author adds chapter', as_(A,f"insert into chapters(story_id,position,title,body) values ('{S1}',1,'One','The tide came in.')"))
ok('other user cannot add chapter', as_(B,f"insert into chapters(story_id,position,title,body) values ('{S1}',2,'Hack','x')"), False, 'row-level security')
ok('chapter over 40,000 chars rejected', as_(A,f"insert into chapters(story_id,position,title,body) values ('{S1}',2,'Big',repeat('a',40001))"), False, 'check constraint')
ok('duplicate chapter position rejected', as_(A,f"insert into chapters(story_id,position,title,body) values ('{S1}',1,'Dup','x')"), False, 'duplicate key')
ok('chapter cannot be inserted already published', as_(A,f"insert into chapters(story_id,position,title,body,status) values ('{S1}',3,'P','x','published')"), False, 'permission denied')
# publish
ok('non-owner cannot publish', as_(B,f"select publish_story('{S1}')"), False, 'not_found_or_not_owner')
ok('anon cannot call publish', as_(None,f"select publish_story('{S1}')",'anon'), False, 'permission denied')
S2=sh(DB,f"insert into stories(author_id,title,synopsis) values ('{A}','Empty one','Nothing inside yet at all.') returning id").stdout.split()[0]
ok('cannot publish a written story with no chapter text', as_(A,f"select publish_story('{S2}')"), False, 'needs_a_chapter_with_text')
ok('owner publishes story', as_(A,f"select publish_story('{S1}')"))
def count(uid,sql,role='authenticated'):
    pre=f"begin; set local role {role}; select set_config('request.jwt.claim.sub','{uid or ''}',true);"
    out=subprocess.run(P+['-d',DB,'-At','-c',pre+sql+"; commit;"],capture_output=True,text=True).stdout.split()
    return out[-1]
def expect(label, got, want):
    global fails
    print('PASS' if str(got)==str(want) else 'FAIL', label, '' if str(got)==str(want) else f'got {got} want {want}'); fails+= str(got)!=str(want)
expect('published story visible to anon', count(None,f"select count(*) from stories where id='{S1}'",'anon'),1)
expect('published chapter visible to reader', count(B,f"select count(*) from chapters where story_id='{S1}'"),1)
sh(DB,f"insert into chapters(story_id,position,title,body) values ('{S1}',2,'Draft two','later')")
expect('draft chapter of published story hidden from reader', count(B,f"select count(*) from chapters where story_id='{S1}'"),1)
expect('draft chapter visible to author', count(A,f"select count(*) from chapters where story_id='{S1}'"),2)
ok('tags set by owner', as_(A,f"select set_story_tags('{S1}', array['Sea ',' lighthouse','sea'])"))
expect('tags normalised and deduped', sh(DB,f"select count(*) from story_tags where story_id='{S1}'").stdout.strip(),2)
ok('non-owner cannot set tags', as_(B,f"select set_story_tags('{S1}', array['x'])"), False, 'not_found_or_not_owner')
ok('more than 8 tags rejected', as_(A,f"select set_story_tags('{S1}', array['a','b','c','d','e','f','g','h','i'])"), False, 'too_many_tags')
ok('clients cannot write tags directly', as_(A,"insert into tags(name) values ('x')"), False, 'permission denied')
# follows
ok('follow someone', as_(B,f"insert into follows(follower_id,followee_id) values ('{B}','{A}')"))
ok('cannot follow as someone else', as_(B,f"insert into follows(follower_id,followee_id) values ('{C}','{A}')"), False, 'row-level security')
ok('cannot follow yourself', as_(B,f"insert into follows(follower_id,followee_id) values ('{B}','{B}')"), False, 'check constraint')
ok('cannot follow twice', as_(B,f"insert into follows(follower_id,followee_id) values ('{B}','{A}')"), False, 'duplicate key')
expect("cannot unfollow someone else's follow", count(C,f"with d as (delete from follows where follower_id='{B}' returning 1) select count(*) from d"),0)
# bookmarks / progress privacy
ok('bookmark published story', as_(B,f"insert into bookmarks(user_id,story_id) values ('{B}','{S1}')"))
expect('bookmarks are private', count(C,"select count(*) from bookmarks"),0)
expect('owner sees own bookmark', count(B,"select count(*) from bookmarks"),1)
ok('cannot bookmark a draft story you do not own', as_(B,f"insert into bookmarks(user_id,story_id) values ('{B}','{S2}')"), False, 'row-level security')
CH=sh(DB,f"select id from chapters where story_id='{S1}' and position=1").stdout.strip()
ok('save reading progress', as_(B,f"insert into reading_progress(user_id,story_id,chapter_id,position) values ('{B}','{S1}','{CH}',0.4)"))
ok('progress upsert update', as_(B,f"update reading_progress set position=0.9 where user_id='{B}' and story_id='{S1}'"))
ok('progress position out of range', as_(B,f"update reading_progress set position=1.5 where user_id='{B}'"), False, 'check constraint')
expect('progress is private', count(C,"select count(*) from reading_progress"),0)
ok('chapter from another story rejected by FK', as_(C,f"insert into reading_progress(user_id,story_id,chapter_id,position) values ('{C}','{S1}','{uuid.uuid4()}',0.1)"), False, 'foreign key')
# likes
ok('like a story', as_(B,f"insert into story_likes(user_id,story_id) values ('{B}','{S1}')"))
ok('cannot like twice', as_(B,f"insert into story_likes(user_id,story_id) values ('{B}','{S1}')"), False, 'duplicate key')
ok('cannot like as another user', as_(B,f"insert into story_likes(user_id,story_id) values ('{C}','{S1}')"), False, 'row-level security')
ok('cannot like a draft', as_(B,f"insert into story_likes(user_id,story_id) values ('{B}','{S2}')"), False, 'row-level security')
# reviews
ok('review a story', as_(B,f"insert into reviews(story_id,user_id,rating,body) values ('{S1}','{B}',5,'Lovely')"))
ok('one review per reader', as_(B,f"insert into reviews(story_id,user_id,rating) values ('{S1}','{B}',4)"), False, 'duplicate key')
ok('rating must be 1-5', as_(C,f"insert into reviews(story_id,user_id,rating) values ('{S1}','{C}',6)"), False, 'check constraint')
ok('author cannot review own story', as_(A,f"insert into reviews(story_id,user_id,rating) values ('{S1}','{A}',5)"), False, 'row-level security')
expect("cannot edit someone else's review", count(C,f"with u as (update reviews set body='x' where user_id='{B}' returning 1) select count(*) from u"),0)
# comments
ok('comment on story', as_(B,f"insert into comments(story_id,user_id,body) values ('{S1}','{B}','Great opening')"))
CM=sh(DB,"select id from comments limit 1").stdout.strip()
ok('threaded reply', as_(C,f"insert into comments(story_id,user_id,parent_id,body) values ('{S1}','{C}','{CM}','Agreed')"))
ok('reply parent from another story rejected', as_(C,f"insert into comments(story_id,user_id,parent_id,body) values ('{S2}','{C}','{CM}','x')"), False, 'row-level security')
ok('empty comment rejected', as_(B,f"insert into comments(story_id,user_id,body) values ('{S1}','{B}','   ')"), False, 'check constraint')
expect("reader cannot delete someone else's comment", count(C,f"with d as (delete from comments where id='{CM}' returning 1) select count(*) from d"),0)
expect('story author can moderate (delete) comment on own story', count(A,f"with d as (delete from comments where id='{CM}' returning 1) select count(*) from d"),1)
expect('replies cascade with parent', sh(DB,"select count(*) from comments").stdout.strip(),0)
# stats view does not leak
expect('stats view hides draft from reader', count(B,f"select count(*) from story_stats where story_id='{S2}'"),0)
expect('stats view counts likes', count(B,f"select like_count from story_stats where story_id='{S1}'"),1)
# unpublish and delete
ok('non-owner cannot unpublish', as_(B,f"select unpublish_story('{S1}')"), False, 'not_found_or_not_owner')
ok('owner unpublishes', as_(A,f"select unpublish_story('{S1}')"))
expect('unpublished story hidden again', count(B,f"select count(*) from stories where id='{S1}'"),0)
# account deletion cascades
sh(DB,f"delete from auth.users where id='{A}'")
expect('deleting the auth user removes profile, stories, chapters', sh(DB,f"select (select count(*) from profiles where id='{A}')+(select count(*) from stories where author_id='{A}')+(select count(*) from chapters)").stdout.strip(),0)
# privilege audit
expect('anon has no write privileges anywhere', sh(DB,"select count(*) from information_schema.role_table_grants where grantee='anon' and table_schema='public' and privilege_type<>'SELECT'").stdout.strip(),0)
expect('RLS enabled on every public table', sh(DB,"select count(*) from pg_tables where schemaname='public' and not rowsecurity").stdout.strip(),0)
print('\nFAILURES:',fails); sys.exit(1 if fails else 0)
