\set ON_ERROR_STOP on
-- Exécuter exclusivement sur la base PostgreSQL éphémère de GitHub Actions.
INSERT INTO public.jkbat_staff_assignments(id,staff_user_id,source_type,source_id,title)
VALUES ('77777777-7777-4777-8777-777777777777','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','TACHE','v7-sans-pieces','Mission fictive');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
DO $f$ DECLARE r jsonb; BEGIN
 r=public.jkbat_v7_withdraw_own_assignment('77777777-7777-4777-8777-777777777777');
 IF r->>'result'<>'withdrawn' THEN RAISE EXCEPTION 'retrait failed'; END IF;
 r=public.jkbat_v7_withdraw_own_assignment('77777777-7777-4777-8777-777777777777');
 IF r->>'result'<>'already_withdrawn' THEN RAISE EXCEPTION 'idempotence failed'; END IF;
END $f$;
RESET ROLE;
DO $f$ BEGIN
 IF (SELECT count(*) FROM public.jkbat_v7_team_withdrawals WHERE source_id='v7-sans-pieces' AND active)!=1
 THEN RAISE EXCEPTION 'tombstone missing'; END IF;
 IF (SELECT count(*) FROM public.jkbat_staff_assignments WHERE source_id='v7-sans-pieces' AND archived_at IS NOT NULL)!=1
 THEN RAISE EXCEPTION 'archive missing'; END IF;
END $f$;
INSERT INTO public.jkbat_staff_assignments(id,staff_user_id,source_type,source_id,title)
VALUES ('88888888-8888-4888-8888-888888888888','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','TACHE','v7-sans-pieces','Replay')
ON CONFLICT (source_type,source_id) DO UPDATE SET archived_at=NULL;
DO $f$ BEGIN
 IF EXISTS(SELECT 1 FROM public.jkbat_staff_assignments WHERE source_id='v7-sans-pieces' AND archived_at IS NULL)
 THEN RAISE EXCEPTION 'replay bypass'; END IF;
END $f$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','cccccccc-cccc-4ccc-8ccc-cccccccccccc',false);
DO $f$ BEGIN
 BEGIN
  PERFORM public.jkbat_v7_withdraw_own_assignment('77777777-7777-4777-8777-777777777777');
  RAISE EXCEPTION 'ownership bypass';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $f$;
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','dddddddd-dddd-4ddd-8ddd-dddddddddddd',false);
DO $f$ BEGIN
 BEGIN
  PERFORM public.jkbat_v7_withdraw_own_assignment('77777777-7777-4777-8777-777777777777');
  RAISE EXCEPTION 'inactive bypass';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $f$;
RESET ROLE;
INSERT INTO public.jkbat_staff_assignments(id,staff_user_id,source_type,source_id,title)
VALUES ('99999999-9999-4999-8999-999999999999','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','TACHE','v7-avec-pieces','Mission fictive avec pièces');
INSERT INTO public.jkbat_staff_reports(assignment_id,report)
VALUES('99999999-9999-4999-8999-999999999999','rapport fictif');
INSERT INTO public.jkbat_staff_media(id,assignment_id,file_name)
VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','99999999-9999-4999-8999-999999999999','preuve-fictive.jpg');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
DO $f$ DECLARE r jsonb; BEGIN
 r=public.jkbat_v7_withdraw_own_assignment('99999999-9999-4999-8999-999999999999');
 IF r->>'result'<>'withdrawn' THEN RAISE EXCEPTION 'retrait with documents failed'; END IF;
END $f$;
RESET ROLE;
DO $f$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.jkbat_staff_reports WHERE assignment_id='99999999-9999-4999-8999-999999999999')
 OR NOT EXISTS(SELECT 1 FROM public.jkbat_staff_media WHERE assignment_id='99999999-9999-4999-8999-999999999999')
 THEN RAISE EXCEPTION 'DOCUMENT LOST'; END IF;
 BEGIN
   DELETE FROM public.jkbat_staff_assignments WHERE id='99999999-9999-4999-8999-999999999999';
   RAISE EXCEPTION 'physical delete allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
END $f$;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
DO $f$ BEGIN
 BEGIN
  PERFORM public.jkbat_v7_admin_restore_assignment('99999999-9999-4999-8999-999999999999','cccccccc-cccc-4ccc-8ccc-cccccccccccc');
  RAISE EXCEPTION 'restore despite documents';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END $f$;
RESET ROLE;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',false);
DO $f$ DECLARE r jsonb; BEGIN
 r=public.jkbat_v7_admin_restore_assignment('77777777-7777-4777-8777-777777777777','cccccccc-cccc-4ccc-8ccc-cccccccccccc');
 IF r->>'result'<>'explicit_restored' THEN RAISE EXCEPTION 'admin restore failed'; END IF;
END $f$;
RESET ROLE;
DO $f$ BEGIN
 IF EXISTS(SELECT 1 FROM public.jkbat_v7_team_withdrawals WHERE source_id='v7-sans-pieces' AND active)
 THEN RAISE EXCEPTION 'restored tombstone still active'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.jkbat_staff_assignments WHERE source_id='v7-sans-pieces' AND staff_user_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc' AND archived_at IS NULL)
 THEN RAISE EXCEPTION 'restoration state invalid'; END IF;
END $f$;

-- Test durci : une mission avec started_at renseigné est non retirable,
-- même si un vieux client laisse le statut « À FAIRE ».
INSERT INTO public.jkbat_staff_assignments
 (id,staff_user_id,source_type,source_id,title,status,started_at)
VALUES ('12121212-1212-4212-8212-121212121212',
 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','TACHE','v7-deja-commencee',
 'Mission commencée','À FAIRE',clock_timestamp());
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
DO $f$ BEGIN
 BEGIN
   PERFORM public.jkbat_v7_withdraw_own_assignment('12121212-1212-4212-8212-121212121212');
   RAISE EXCEPTION 'STARTED_ASSIGNMENT_WITHDRAWN';
 EXCEPTION WHEN invalid_parameter_value THEN NULL;
 END;
END $f$;
RESET ROLE;
DO $f$ BEGIN
 IF EXISTS(SELECT 1 FROM public.jkbat_staff_assignments
  WHERE source_id='v7-deja-commencee' AND archived_at IS NOT NULL)
 THEN RAISE EXCEPTION 'STARTED_ASSIGNMENT_ARCHIVED'; END IF;
END $f$;

-- Test durci : impossible de changer la source d'une mission retirée
-- pour contourner le marqueur V7 (l'ancien client ne doit rien effacer).
DO $f$ BEGIN
 BEGIN
  UPDATE public.jkbat_staff_assignments SET source_id='v7-changement-interdit'
  WHERE id='99999999-9999-4999-8999-999999999999';
  RAISE EXCEPTION 'WITHDRAWN_SOURCE_CHANGED';
 EXCEPTION WHEN insufficient_privilege THEN NULL;
 END;
 IF NOT EXISTS(SELECT 1 FROM public.jkbat_staff_assignments
  WHERE id='99999999-9999-4999-8999-999999999999'
  AND source_id='v7-avec-pieces' AND archived_at IS NOT NULL)
 THEN RAISE EXCEPTION 'WITHDRAWN_RECORD_MUTATED'; END IF;
END $f$;
\echo JKBAT V7: protections source + mission commenced passed.
\echo JKBAT V7: PostgreSQL 17 integration tests passed (fictional data only).
