import os, subprocess, sys, uuid, re
HERE=os.path.dirname(os.path.abspath(__file__)); ROOT=os.path.dirname(HERE)
# Connection: set PGHOST/PGPORT/PGUSER as for psql (a throw-away local Postgres 15+ is enough).
P=['psql','-X','-q','-v','ON_ERROR_STOP=1']
def sh(db, sql):
    r=subprocess.run(P+['-d',db,'-At','-c',sql],capture_output=True,text=True); return r
def f(db, path):
    r=subprocess.run(P+['-d',db,'-f',path],capture_output=True,text=True); return r
DB='sstest'
sh('postgres',f'drop database if exists {DB}'); sh('postgres',f'create database {DB}')
for p in [HERE+'/stub_supabase.sql']+[ROOT+'/migrations/'+m for m in
  ['20261024000001_schema.sql','20261024000002_security.sql','20261024000003_functions.sql']]+[ROOT+'/seed.sql']:
    r=f(DB,p)
    if r.returncode: print('MIGRATION FAIL',p,r.stderr); sys.exit(1)
print('migrations + seed applied cleanly')
fails=0
def mk(name,role='reader'):
    u=str(uuid.uuid4())
    r=sh(DB,f"insert into auth.users(id,email,raw_user_meta_data) values ('{u}','{name}@x.io', jsonb_build_object('display_name','{name}','role','{role}'))")
    assert r.returncode==0, r.stderr
    return u
def as_(uid, sql, role='authenticated'):
    pre=f"begin; set local role {role}; select set_config('request.jwt.claim.sub','{uid or ''}',true);"
    r=sh(DB,pre+sql+"; commit;")
    return r
def ok(label, r, expect_ok=True, contains=None):
    global fails
    good=(r.returncode==0)==expect_ok
    if good and contains and not expect_ok: good = contains in r.stderr
    print(('PASS' if good else 'FAIL'),label, '' if good else (r.stderr.strip()[:200] or r.stdout[:200]))
    if not good: fails+=1
