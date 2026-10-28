\set ON_ERROR_STOP on
-- JKBat: preuve PostgreSQL ISOLÉE et 100% fictive. NE PAS APPLIQUER à Supabase.
CREATE SCHEMA auth;
CREATE ROLE authenticated NOLOGIN;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $f$
 SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$f$;
CREATE TABLE public.jkbat_admins (user_id uuid PRIMARY KEY);
CREATE TABLE public.jkbat_staff_profiles (id uuid PRIMARY KEY, active boolean NOT NULL, approval_status text NOT NULL);
CREATE TABLE public.jkbat_staff_assignments (
 id uuid PRIMARY KEY, staff_user_id uuid NOT NULL, source_type text NOT NULL,
 source_id text NOT NULL, title text NOT NULL DEFAULT 'Test', status text NOT NULL DEFAULT 'À FAIRE',
 archived_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now(),
 completed_at timestamptz, UNIQUE(source_type,source_id)
);
CREATE TABLE public.jkbat_staff_reports (
 assignment_id uuid PRIMARY KEY REFERENCES public.jkbat_staff_assignments(id) ON DELETE CASCADE,
 report text NOT NULL
);
CREATE TABLE public.jkbat_staff_media (
 id uuid PRIMARY KEY, assignment_id uuid NOT NULL REFERENCES public.jkbat_staff_assignments(id) ON DELETE CASCADE,
 file_name text NOT NULL
);
CREATE TABLE public.jkbat_v73_team_withdrawals (
 source_type text NOT NULL, source_id text NOT NULL,
 active boolean NOT NULL DEFAULT true, revision int NOT NULL DEFAULT 1,
 PRIMARY KEY(source_type,source_id)
);
CREATE TABLE public.jkbat_client_appointments (
 id uuid PRIMARY KEY, client_id uuid NOT NULL, source_type text NOT NULL, source_id text NOT NULL,
 title text NOT NULL
);
CREATE TABLE public.jkbat_v73_client_withdrawals (
 client_id uuid NOT NULL, source_type text NOT NULL, source_id text NOT NULL,
 active boolean NOT NULL DEFAULT true, PRIMARY KEY(client_id,source_type,source_id)
);
CREATE FUNCTION public.jkbat_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $f$
 SELECT EXISTS(SELECT 1 FROM public.jkbat_admins a WHERE a.user_id=auth.uid())
$f$;
CREATE FUNCTION public.jkbat_staff_is_active(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $f$
 SELECT EXISTS(SELECT 1 FROM public.jkbat_staff_profiles p
 WHERE p.id=p_id AND p.active AND p.approval_status='approved')
$f$;
CREATE FUNCTION public.jkbat_fake_delete_block() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
 IF upper(trim(old.source_type)) IN ('TACHE','RDV','INTERVENTION','RECURRENCE') THEN
  RAISE EXCEPTION 'NO_PHYSICAL_DELETE' USING ERRCODE='42501';
 END IF;
 RETURN old;
END $f$;
CREATE TRIGGER no_delete BEFORE DELETE ON public.jkbat_staff_assignments
 FOR EACH ROW EXECUTE FUNCTION public.jkbat_fake_delete_block();
CREATE FUNCTION public.jkbat_fake_replay_guard() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
 IF NEW.archived_at IS NULL AND EXISTS (
 SELECT 1 FROM public.jkbat_v73_team_withdrawals w
 WHERE w.source_type=NEW.source_type AND w.source_id=NEW.source_id AND w.active
 ) THEN RETURN NULL; END IF;
 RETURN NEW;
END $f$;
CREATE TRIGGER guard_replay BEFORE INSERT OR UPDATE ON public.jkbat_staff_assignments
 FOR EACH ROW EXECUTE FUNCTION public.jkbat_fake_replay_guard();
CREATE FUNCTION public.jkbat_test_withdraw(p_id uuid) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $f$
DECLARE a public.jkbat_staff_assignments%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL OR NOT public.jkbat_staff_is_active(auth.uid()) THEN
  RAISE EXCEPTION 'NOT_ACTIVE' USING ERRCODE='42501'; END IF;
 SELECT * INTO a FROM public.jkbat_staff_assignments WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RETURN jsonb_build_object('ok',false); END IF;
 IF a.staff_user_id IS DISTINCT FROM auth.uid() THEN
  RAISE EXCEPTION 'NOT_OWNER' USING ERRCODE='42501'; END IF;
 IF a.source_type NOT IN ('TACHE','RDV','INTERVENTION','RECURRENCE')
 OR upper(a.status) NOT IN ('À FAIRE','A FAIRE') OR a.completed_at IS NOT NULL THEN
  RAISE EXCEPTION 'NOT_WITHDRAWABLE' USING ERRCODE='22023'; END IF;
 IF a.archived_at IS NOT NULL THEN
  RETURN jsonb_build_object('ok',true,'result','already_withdrawn'); END IF;
 UPDATE public.jkbat_staff_assignments SET archived_at=clock_timestamp(),updated_at=clock_timestamp()
 WHERE id=p_id;
 INSERT INTO public.jkbat_v73_team_withdrawals(source_type,source_id)
 VALUES(a.source_type,a.source_id)
 ON CONFLICT(source_type,source_id) DO UPDATE SET active=true,revision=public.jkbat_v73_team_withdrawals.revision+1;
 RETURN jsonb_build_object('ok',true,'result','withdrawn');
END $f$;
CREATE FUNCTION public.jkbat_fake_client_delete() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
 INSERT INTO public.jkbat_v73_client_withdrawals(client_id,source_type,source_id)
 VALUES(old.client_id,old.source_type,old.source_id)
 ON CONFLICT(client_id,source_type,source_id) DO UPDATE SET active=true;
 RETURN old;
END $f$;
CREATE TRIGGER client_withdrawn AFTER DELETE ON public.jkbat_client_appointments
 FOR EACH ROW EXECUTE FUNCTION public.jkbat_fake_client_delete();
CREATE FUNCTION public.jkbat_fake_client_guard() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
 IF EXISTS (SELECT 1 FROM public.jkbat_v73_client_withdrawals w WHERE
 w.client_id=NEW.client_id AND w.source_type=NEW.source_type AND
 w.source_id=NEW.source_id AND w.active) THEN RETURN NULL; END IF;
 RETURN NEW;
END $f$;
CREATE TRIGGER client_no_replay BEFORE INSERT ON public.jkbat_client_appointments
 FOR EACH ROW EXECUTE FUNCTION public.jkbat_fake_client_guard();

INSERT INTO public.jkbat_admins VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
INSERT INTO public.jkbat_staff_profiles VALUES
 ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',true,'approved'),
 ('cccccccc-cccc-4ccc-8ccc-cccccccccccc',true,'approved'),
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd',false,'pending');
INSERT INTO public.jkbat_staff_assignments(id,staff_user_id,source_type,source_id)
 VALUES ('11111111-1111-4111-8111-111111111111','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','TACHE','fictive-1');
INSERT INTO public.jkbat_staff_reports VALUES ('11111111-1111-4111-8111-111111111111','rapport fictif');
INSERT INTO public.jkbat_staff_media VALUES
 ('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111','image-fictive.jpg');
GRANT USAGE ON SCHEMA auth,public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth,public TO authenticated;

-- Technicien affecté peut retirer; documents doivent rester intacts.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',false);
SELECT public.jkbat_test_withdraw('11111111-1111-4111-8111-111111111111');
RESET ROLE;
DO $f$ BEGIN
 IF (SELECT archived_at IS NULL FROM public.jkbat_staff_assignments WHERE source_id='fictive-1') THEN
  RAISE EXCEPTION 'mission encore visible'; END IF;
 IF (SELECT count(*) FROM public.jkbat_staff_reports)!=1 OR
    (SELECT count(*) FROM public.jkbat_staff_media)!=1 THEN
  RAISE EXCEPTION 'documents effaces'; END IF;
END $f$;

-- Notification/synchronisation répétée: aucun retour de mission.
INSERT INTO public.jkbat_staff_assignments(id,staff_user_id,source_type,source_id)
 VALUES('33333333-3333-4333-8333-333333333333','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','TACHE','fictive-1')
 ON CONFLICT(source_type,source_id) DO UPDATE SET archived_at=null;
DO $f$ BEGIN
 IF (SELECT count(*) FROM public.jkbat_staff_assignments WHERE source_id='fictive-1' AND archived_at IS NULL)!=0 THEN
  RAISE EXCEPTION 'reapparition automatique'; END IF;
END $f$;

-- Un autre technicien ne peut pas retirer la mission.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','cccccccc-cccc-4ccc-8ccc-cccccccccccc',false);
DO $f$ BEGIN
 BEGIN
  PERFORM public.jkbat_test_withdraw('11111111-1111-4111-8111-111111111111');
  RAISE EXCEPTION 'authorization bypass';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $f$;
RESET ROLE;

-- Un compte non approuvé n'a pas de droit de retrait.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','dddddddd-dddd-4ddd-8ddd-dddddddddddd',false);
DO $f$ BEGIN
 BEGIN
  PERFORM public.jkbat_test_withdraw('11111111-1111-4111-8111-111111111111');
  RAISE EXCEPTION 'inactive user accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $f$;
RESET ROLE;

-- Une suppression physique de tâche est interdite (FK CASCADE protégées).
DO $f$ BEGIN
 BEGIN
  DELETE FROM public.jkbat_staff_assignments WHERE source_id='fictive-1';
  RAISE EXCEPTION 'physical delete accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF (SELECT count(*) FROM public.jkbat_staff_reports)!=1 THEN
  RAISE EXCEPTION 'report lost after delete'; END IF;
END $f$;

-- La messagerie CHAT n'est pas une mission et peut conserver son comportement antérieur.
INSERT INTO public.jkbat_staff_assignments(id,staff_user_id,source_type,source_id)
 VALUES('44444444-4444-4444-8444-444444444444','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','CHAT','fictif-chat');
DELETE FROM public.jkbat_staff_assignments WHERE source_id='fictif-chat';
DO $f$ BEGIN
 IF EXISTS(SELECT 1 FROM public.jkbat_staff_assignments WHERE source_id='fictif-chat')
 THEN RAISE EXCEPTION 'chat blocked'; END IF;
END $f$;

-- Client peut retirer sa vue sans retirer la mission de l'Équipe.
INSERT INTO public.jkbat_client_appointments VALUES
 ('55555555-5555-4555-8555-555555555555','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','TACHE','client-fictif','test fictif');
DELETE FROM public.jkbat_client_appointments WHERE source_id='client-fictif';
INSERT INTO public.jkbat_client_appointments VALUES
 ('66666666-6666-4666-8666-666666666666','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','TACHE','client-fictif','retour automatique');
DO $f$ BEGIN
 IF EXISTS(SELECT 1 FROM public.jkbat_client_appointments WHERE source_id='client-fictif')
 THEN RAISE EXCEPTION 'client appointment replayed'; END IF;
 IF (SELECT count(*) FROM public.jkbat_staff_reports)!=1 OR
 (SELECT count(*) FROM public.jkbat_staff_media)!=1 THEN
 RAISE EXCEPTION 'documents lost'; END IF;
END $f$;
\echo VALIDATION PASS: PostgreSQL reel, donnees fictives, retrait non destructif et anti-reapparition.
