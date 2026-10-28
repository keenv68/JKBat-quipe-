#!/usr/bin/env python3
"""Concurrence réelle PostgreSQL 17, données fictives, jamais Supabase prod."""
import os
import subprocess
import time

DB = dict(os.environ)
DB["PGOPTIONS"] = "-c statement_timeout=8000"

def psql(sql, *, check=True):
    r = subprocess.run(
        ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True, text=True, env=DB, timeout=18
    )
    if check and r.returncode:
        raise AssertionError(f"SQL failed: {r.stderr[-1800:]}")
    return r

def begin(sql):
    return subprocess.Popen(
        ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=DB
    )

staff = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

# COURSE A : retrait valide alors qu'un ancien Pro tente un UPSERT.
id1 = "13131313-1313-4313-8313-131313131313"
psql(f"""INSERT INTO public.jkbat_staff_assignments
  (id, staff_user_id, source_type, source_id, title)
VALUES ('{id1}', '{staff}', 'TACHE', 'v7-course-upsert', 'Race A')""")
txA = begin(f"""
 BEGIN;
 SET ROLE authenticated;
 SELECT set_config('request.jwt.claim.sub','{staff}',true);
 SELECT public.jkbat_v7_withdraw_own_assignment('{id1}');
 SELECT pg_sleep(1.2);
 COMMIT;""")
time.sleep(0.3)
txB = begin(f"""INSERT INTO public.jkbat_staff_assignments
(id,staff_user_id,source_type,source_id,title,status,archived_at)
VALUES ('14141414-1414-4414-8414-141414141414','{staff}','TACHE','v7-course-upsert','Old Pro','À FAIRE',null)
ON CONFLICT(source_type,source_id) DO UPDATE SET status='À FAIRE',archived_at=null;""")
for name, proc in [("retrait A", txA), ("ancien UPSERT",txB)]:
    stdout, stderr = proc.communicate(timeout=12)
    if proc.returncode:
        raise AssertionError(f"{name}: rc={proc.returncode}: {stderr[-1300:]}")
r = psql("""SELECT (archived_at IS NOT NULL)::text || ':' ||
 (SELECT active::text FROM public.jkbat_v7_team_withdrawals
 WHERE source_type='TACHE' AND source_id='v7-course-upsert')
 FROM public.jkbat_staff_assignments WHERE source_id='v7-course-upsert';""").stdout.strip()
assert r == "true:true", "After concurrent UPSERT, deleted work reappeared: " + r
print("PASS: retrait concurrent VS UPSERT ancien Pro, sans réapparition")

# COURSE B : ancien UPDATE prend d'abord le verrou de ligne,
# retrait tente ensuite le verrou advisory; recherche de deadlock.
id2="15151515-1515-4515-8515-151515151515"
psql(f"""INSERT INTO public.jkbat_staff_assignments
(id,staff_user_id,source_type,source_id,title)
VALUES ('{id2}','{staff}','TACHE','v7-course-update','Race B')""")
oldPro = begin(f"""
BEGIN;
SET lock_timeout='5s';
SELECT id FROM public.jkbat_staff_assignments WHERE id='{id2}' FOR UPDATE;
SELECT pg_sleep(1.2);
UPDATE public.jkbat_staff_assignments SET title='old sync' WHERE id='{id2}';
COMMIT;""")
time.sleep(0.25)
tech = begin(f"""
BEGIN;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','{staff}',true);
SET lock_timeout='5s';
SELECT public.jkbat_v7_withdraw_own_assignment('{id2}');
COMMIT;""")
for name, proc in [("ancien UPDATE",oldPro),("retrait B",tech)]:
    stdout, stderr = proc.communicate(timeout=12)
    if proc.returncode:
        raise AssertionError(f"{name}: deadlock/timeout/code={proc.returncode}: {stderr[-1300:]}")
r=psql("""SELECT (archived_at IS NOT NULL)::text || ':' ||
 (SELECT active::text FROM public.jkbat_v7_team_withdrawals
 WHERE source_type='TACHE' AND source_id='v7-course-update')
 FROM public.jkbat_staff_assignments WHERE source_id='v7-course-update';""").stdout.strip()
assert r == "true:true", "Concurrent update resurrected withdrawn mission: "+r
print("PASS: ancien UPDATE concurrent, aucune interblocage et archivage durable")
