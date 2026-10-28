-- JKBat | Retrait durable des missions : candidate de validation ISOLÉE
-- NE PAS APPLIQUER directement à Supabase de production.
-- Aucune suppression de mission opérationnelle ni de pièces liées.
BEGIN;

CREATE TABLE public.jkbat_v7_team_withdrawals (
 source_type text NOT NULL,
 source_id text NOT NULL,
 previous_staff_user_id uuid NOT NULL,
 actor_user_id uuid NOT NULL,
 withdrawn_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 active boolean NOT NULL DEFAULT true,
 revision bigint NOT NULL DEFAULT 1 CHECK(revision > 0),
 restored_at timestamptz,
 PRIMARY KEY(source_type,source_id),
 CHECK(source_type IN ('RDV','TACHE','RECURRENCE','INTERVENTION'))
);
ALTER TABLE public.jkbat_v7_team_withdrawals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.jkbat_v7_team_withdrawals FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.jkbat_v7_guard_assignment_replay() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE st text:=upper(btrim(coalesce(NEW.source_type,'')));
        sid text:=btrim(coalesce(NEW.source_id,''));
BEGIN
 -- Un ancien client ne doit pas pouvoir changer la clef source d'une mission retiree
 -- pour contourner le marqueur de retrait et ses pieces liees.
 IF TG_OP='UPDATE' AND (
    upper(btrim(coalesce(OLD.source_type,'')))<>st
    OR btrim(coalesce(OLD.source_id,''))<>sid
 ) AND upper(btrim(coalesce(OLD.source_type,''))) IN
     ('RDV','TACHE','RECURRENCE','INTERVENTION') THEN
   PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
     'JKBAT-V7:'||upper(btrim(OLD.source_type))||':'||btrim(OLD.source_id),0));
   IF EXISTS(SELECT 1 FROM public.jkbat_v7_team_withdrawals
     WHERE source_type=upper(btrim(OLD.source_type))
       AND source_id=btrim(OLD.source_id) AND active) THEN
     RAISE EXCEPTION 'JKBAT_V7_CANNOT_CHANGE_WITHDRAWN_SOURCE'
       USING ERRCODE='42501';
   END IF;
 END IF;
 IF st IN ('RDV','TACHE','RECURRENCE','INTERVENTION') AND sid<>'' THEN
   PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('JKBAT-V7:'||st||':'||sid,0));
   IF EXISTS(
     SELECT 1 FROM public.jkbat_v7_team_withdrawals
     WHERE source_type=st AND source_id=sid AND active
   ) THEN RETURN NULL; END IF;
 END IF;
 RETURN NEW;
END $fn$;
CREATE TRIGGER jkbat_v7_guard_assignment_replay_trg
 BEFORE INSERT OR UPDATE ON public.jkbat_staff_assignments
 FOR EACH ROW EXECUTE FUNCTION public.jkbat_v7_guard_assignment_replay();

CREATE FUNCTION public.jkbat_v7_block_operational_delete() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF upper(btrim(coalesce(OLD.source_type,''))) IN
 ('RDV','TACHE','RECURRENCE','INTERVENTION') THEN
  RAISE EXCEPTION 'JKBAT_V7_PHYSICAL_DELETE_FORBIDDEN' USING ERRCODE='42501';
 END IF;
 RETURN OLD;
END $fn$;
CREATE TRIGGER jkbat_v7_block_operational_delete_trg
 BEFORE DELETE ON public.jkbat_staff_assignments
 FOR EACH ROW EXECUTE FUNCTION public.jkbat_v7_block_operational_delete();

CREATE FUNCTION public.jkbat_v7_withdraw_own_assignment(p_assignment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE a public.jkbat_staff_assignments%ROWTYPE;
        st text; sid text; current_status text;
BEGIN
 IF auth.uid() IS NULL OR NOT public.jkbat_staff_is_active(auth.uid()) THEN
  RAISE EXCEPTION 'JKBAT_V7_STAFF_AUTH_REQUIRED' USING ERRCODE='42501';
 END IF;
 SELECT * INTO a FROM public.jkbat_staff_assignments WHERE id=p_assignment_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'result','not_found'); END IF;
 st:=upper(btrim(coalesce(a.source_type,'')));
 sid:=btrim(coalesce(a.source_id,''));
 IF st NOT IN ('RDV','TACHE','RECURRENCE','INTERVENTION') OR sid='' THEN
  RAISE EXCEPTION 'JKBAT_V7_NOT_OPERATIONAL' USING ERRCODE='22023';
 END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('JKBAT-V7:'||st||':'||sid,0));
 SELECT * INTO a FROM public.jkbat_staff_assignments WHERE id=p_assignment_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'result','not_found'); END IF;
 IF a.staff_user_id IS DISTINCT FROM auth.uid() THEN
  RAISE EXCEPTION 'JKBAT_V7_NOT_YOUR_ASSIGNMENT' USING ERRCODE='42501';
 END IF;
 -- Re-verifier source et etat APRES l'acquisition du verrou.
 IF upper(btrim(coalesce(a.source_type,'')))<>st OR btrim(coalesce(a.source_id,''))<>sid THEN
  RAISE EXCEPTION 'JKBAT_V7_CONCURRENT_CHANGE' USING ERRCODE='40001';
 END IF;
 IF a.archived_at IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM public.jkbat_v7_team_withdrawals
     WHERE source_type=st AND source_id=sid AND active) THEN
     RETURN jsonb_build_object('ok',true,'result','already_withdrawn');
  END IF;
  RAISE EXCEPTION 'JKBAT_V7_ARCHIVED_NOT_WITHDRAWABLE' USING ERRCODE='22023';
 END IF;
 current_status:=upper(btrim(coalesce(a.status,'')));
 IF current_status NOT IN ('À FAIRE','A FAIRE','A_FAIRE') OR a.completed_at IS NOT NULL OR a.started_at IS NOT NULL THEN
  RAISE EXCEPTION 'JKBAT_V7_MISSION_IN_PROGRESS_OR_DONE' USING ERRCODE='22023';
 END IF;
 -- Le marqueur vient apres l'archivage : ne bloque pas notre propre UPDATE.
 UPDATE public.jkbat_staff_assignments
 SET archived_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=p_assignment_id;
 INSERT INTO public.jkbat_v7_team_withdrawals
 (source_type,source_id,previous_staff_user_id,actor_user_id)
 VALUES(st,sid,a.staff_user_id,auth.uid())
 ON CONFLICT(source_type,source_id) DO UPDATE SET
  previous_staff_user_id=EXCLUDED.previous_staff_user_id,
  actor_user_id=EXCLUDED.actor_user_id,
  active=true,withdrawn_at=clock_timestamp(),restored_at=NULL,
  revision=public.jkbat_v7_team_withdrawals.revision+1;
 RETURN jsonb_build_object('ok',true,'result','withdrawn');
END $fn$;

-- La restauration ne doit JAMAIS remettre a zero une intervention avec historique.
CREATE FUNCTION public.jkbat_v7_admin_restore_assignment(p_assignment_id uuid,p_staff_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE a public.jkbat_staff_assignments%ROWTYPE; st text; sid text;
BEGIN
 IF auth.uid() IS NULL OR NOT public.jkbat_is_admin() THEN
  RAISE EXCEPTION 'JKBAT_V7_ADMIN_REQUIRED' USING ERRCODE='42501';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.jkbat_staff_profiles
     WHERE id=p_staff_user_id AND active AND approval_status='approved') THEN
  RAISE EXCEPTION 'JKBAT_V7_STAFF_NOT_APPROVED' USING ERRCODE='22023';
 END IF;
 SELECT * INTO a FROM public.jkbat_staff_assignments WHERE id=p_assignment_id;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'result','not_found'); END IF;
 st:=upper(btrim(coalesce(a.source_type,''))); sid:=btrim(coalesce(a.source_id,''));
 IF st NOT IN ('RDV','TACHE','RECURRENCE','INTERVENTION') OR sid='' THEN
  RAISE EXCEPTION 'JKBAT_V7_NOT_OPERATIONAL' USING ERRCODE='22023';
 END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('JKBAT-V7:'||st||':'||sid,0));
 SELECT * INTO a FROM public.jkbat_staff_assignments WHERE id=p_assignment_id FOR UPDATE;
 IF a.id IS NULL OR upper(btrim(a.source_type))<>st OR btrim(a.source_id)<>sid THEN
  RAISE EXCEPTION 'JKBAT_V7_CONCURRENT_CHANGE' USING ERRCODE='40001';
 END IF;
 IF a.completed_at IS NOT NULL OR a.started_at IS NOT NULL OR upper(btrim(coalesce(a.status,''))) LIKE 'TERMIN%'
  OR upper(btrim(coalesce(a.status,''))) IN ('EN ROUTE','SUR PLACE','EN COURS','IMPOSSIBLE') THEN
  RAISE EXCEPTION 'JKBAT_V7_HISTORY_LOCKED' USING ERRCODE='23514';
 END IF;
 IF EXISTS(SELECT 1 FROM public.jkbat_staff_reports WHERE assignment_id=a.id)
 OR EXISTS(SELECT 1 FROM public.jkbat_staff_media WHERE assignment_id=a.id)
 OR EXISTS(SELECT 1 FROM public.jkbat_stock_usage WHERE assignment_id=a.id)
 OR EXISTS(SELECT 1 FROM public.jkbat_stock_movements WHERE assignment_id=a.id) THEN
  RAISE EXCEPTION 'JKBAT_V7_HISTORY_REQUIRES_NEW_ASSIGNMENT_REVISION' USING ERRCODE='23514';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.jkbat_v7_team_withdrawals
   WHERE source_type=st AND source_id=sid AND active) THEN
  RAISE EXCEPTION 'JKBAT_V7_NOT_WITHDRAWN' USING ERRCODE='22023';
 END IF;
 UPDATE public.jkbat_v7_team_withdrawals SET active=false,restored_at=clock_timestamp(),
    revision=revision+1 WHERE source_type=st AND source_id=sid;
 UPDATE public.jkbat_staff_assignments SET staff_user_id=p_staff_user_id,
    archived_at=NULL,updated_at=clock_timestamp()
    WHERE id=p_assignment_id;
 RETURN jsonb_build_object('ok',true,'result','explicit_restored');
END $fn$;

REVOKE ALL ON FUNCTION public.jkbat_v7_guard_assignment_replay() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jkbat_v7_block_operational_delete() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.jkbat_v7_withdraw_own_assignment(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.jkbat_v7_admin_restore_assignment(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.jkbat_v7_withdraw_own_assignment(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.jkbat_v7_admin_restore_assignment(uuid,uuid) TO authenticated;
COMMIT;
