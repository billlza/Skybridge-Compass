-- Isolated database only. This uses synthetic identities and always rolls back.
BEGIN;
INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES
 ('11111111-1111-4111-8111-111111111111','first@example.invalid','{"display_name":"First"}'),
 ('22222222-2222-4222-8222-222222222222','second@example.invalid','{"display_name":"Second"}');
INSERT INTO public.user_profiles(id,email) VALUES
 ('11111111-1111-4111-8111-111111111111','first@example.invalid'),
 ('22222222-2222-4222-8222-222222222222','second@example.invalid');
INSERT INTO public.user_settings(user_id,setting_key,setting_value) VALUES
 ('22222222-2222-4222-8222-222222222222','private','second'),
 ('nebula_unrelated_user','private','legacy');
-- Exercise the existing-account avatar path with a real stored object record.
INSERT INTO public.universal_users(universal_id,auth_user_id)
 VALUES ('auth:11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111');
INSERT INTO storage.buckets(id,public) VALUES ('avatars',true);
INSERT INTO storage.objects(bucket_id,name)
 VALUES ('avatars','11111111-1111-4111-8111-111111111111/fixture.png');

-- New objects must stay private even if a migration forgets an explicit revoke.
CREATE TABLE public.advisor_future_table(id integer);
CREATE FUNCTION public.advisor_future_function() RETURNS integer
 LANGUAGE sql SECURITY DEFINER SET search_path='' AS 'SELECT 1';
DO $$
BEGIN
 IF has_table_privilege('anon','public.advisor_future_table','SELECT')
    OR has_table_privilege('authenticated','public.advisor_future_table','INSERT')
    OR has_function_privilege('anon','public.advisor_future_function()','EXECUTE')
    OR has_function_privilege('authenticated','public.advisor_future_function()','EXECUTE') THEN
   RAISE EXCEPTION 'new objects inherited client privileges';
 END IF;
END $$;

SET LOCAL ROLE anon;
DO $$
DECLARE blocked boolean; decision record;
BEGIN
 blocked := false;
 BEGIN PERFORM 1 FROM public.cli_login_sessions; EXCEPTION WHEN insufficient_privilege THEN blocked := true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'anon could read CLI credentials'; END IF;
 blocked := false;
 BEGIN PERFORM 1 FROM public.verification_codes; EXCEPTION WHEN insufficient_privilege THEN blocked := true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'anon could read verification codes'; END IF;
 blocked := false;
 BEGIN PERFORM public.cleanup_old_attempts(); EXCEPTION WHEN insufficient_privilege THEN blocked := true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'anon could execute maintenance'; END IF;
 SELECT * INTO decision FROM public.guard_registration_attempt_v1(
     'unused','email','first@example.invalid','fixture','login','login');
 IF decision.allowed IS DISTINCT FROM true OR decision.audit_ticket IS NULL THEN
   RAISE EXCEPTION 'login guard contract changed';
 END IF;
 PERFORM public.record_registration_attempt_v1('first@example.invalid','email','fixture','login',false,'regression',false,false,decision.audit_ticket,'{"test":"advisor_login"}');
 -- Replaying the same single-use ticket must not duplicate the audit row.
 PERFORM public.record_registration_attempt_v1('first@example.invalid','email','fixture','login',false,'regression',false,false,decision.audit_ticket,'{"test":"advisor_login"}');
 SELECT * INTO decision FROM public.guard_registration_attempt_v1(
     'unused','email','first@example.invalid','','default','register');
 IF decision.allowed IS DISTINCT FROM false THEN RAISE EXCEPTION 'invalid registration guard request accepted'; END IF;
 PERFORM 1 FROM public.constellations;
 PERFORM 1 FROM public.disposable_email_domains;
END $$;

RESET ROLE;
DO $$ BEGIN
 IF (SELECT count(*) FROM public.registration_attempts WHERE metadata->>'test'='advisor_login')<>1 THEN
   RAISE EXCEPTION 'login audit ticket was bypassed or replayed';
 END IF;
END $$;
SELECT set_config('request.jwt.claims','{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE affected integer; blocked boolean; avatar jsonb;
BEGIN
 IF (SELECT count(*) FROM public.profiles) <> 1 THEN RAISE EXCEPTION 'profile ownership read failed'; END IF;
 UPDATE public.profiles SET display_name='Updated' WHERE id='11111111-1111-4111-8111-111111111111';
 GET DIAGNOSTICS affected=ROW_COUNT;
 IF affected<>1 THEN RAISE EXCEPTION 'own profile update denied'; END IF;
 UPDATE public.profiles SET display_name='Attack' WHERE id='22222222-2222-4222-8222-222222222222';
 GET DIAGNOSTICS affected=ROW_COUNT;
 IF affected<>0 THEN RAISE EXCEPTION 'cross-user profile update succeeded'; END IF;
 blocked:=false;
 BEGIN UPDATE public.profiles SET id='22222222-2222-4222-8222-222222222222'
   WHERE id='11111111-1111-4111-8111-111111111111';
 EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'profile ownership could be reassigned'; END IF;
 blocked:=false;
 BEGIN TRUNCATE public.profiles; EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'TRUNCATE bypassed RLS'; END IF;
 INSERT INTO public.user_settings(user_id,setting_key,setting_value)
 VALUES ('11111111-1111-4111-8111-111111111111','theme','dark');
 IF (SELECT count(*) FROM public.user_settings)<>1 THEN RAISE EXCEPTION 'settings ownership failed'; END IF;
 IF public.check_user_profile_access('nebula_unrelated_user') THEN RAISE EXCEPTION 'legacy prefix bypass'; END IF;
 blocked:=false;
 BEGIN INSERT INTO public.user_settings(user_id,setting_key,setting_value) VALUES ('nebula_unrelated_user','attack','bad');
 EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'cross-user settings insert succeeded'; END IF;
 blocked:=false;
 BEGIN PERFORM public.ensure_avatar_universal_user('22222222-2222-4222-8222-222222222222');
 EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'internal avatar helper executable'; END IF;
 avatar:=public.avatar_finalize_upload(
   '11111111-1111-4111-8111-111111111111/fixture.png',
   'https://example.invalid/storage/v1/object/public/avatars/11111111-1111-4111-8111-111111111111/fixture.png');
 IF avatar->>'auth_user_id'<>'11111111-1111-4111-8111-111111111111'
    OR NOT EXISTS (SELECT 1 FROM public.user_profiles
                    WHERE avatar_url=avatar->>'avatar_url') THEN
   RAISE EXCEPTION 'authenticated avatar projection failed';
 END IF;
 blocked:=false;
 BEGIN PERFORM public.avatar_finalize_upload('22222222-2222-4222-8222-222222222222/fixture.png','https://example.invalid/avatar');
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM NOT LIKE 'storage_path must begin%' THEN RAISE; END IF;
   blocked:=true;
 END;
 IF NOT blocked THEN RAISE EXCEPTION 'cross-user avatar path accepted'; END IF;
 IF (public.get_user_binding_status('11111111-1111-4111-8111-111111111111')->>'user_id')
      <> '11111111-1111-4111-8111-111111111111' THEN RAISE EXCEPTION 'own binding status unavailable'; END IF;
 blocked:=false;
 BEGIN PERFORM public.get_user_binding_status('22222222-2222-4222-8222-222222222222');
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM NOT LIKE 'Access denied:%' THEN RAISE; END IF;
   blocked:=true;
 END;
 IF NOT blocked THEN RAISE EXCEPTION 'cross-user binding status readable'; END IF;
END $$;

RESET ROLE;
SELECT set_config('request.jwt.claims','{"role":"authenticated"}',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE blocked boolean:=false;
BEGIN
 BEGIN PERFORM public.get_user_binding_status('11111111-1111-4111-8111-111111111111');
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM NOT LIKE 'Access denied:%' THEN RAISE; END IF;
   blocked:=true;
 END;
 IF NOT blocked THEN RAISE EXCEPTION 'missing identity bypassed binding status check'; END IF;
END $$;

RESET ROLE;
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
DO $$
BEGIN
 PERFORM 1 FROM public.cli_login_sessions;
 PERFORM 1 FROM public.verification_codes;
 PERFORM public.check_auth_attempt_allowed_v1('192.0.2.1','fixture','fixture','login','login');
 IF (SELECT count(*) FROM public.profiles)<>2 THEN RAISE EXCEPTION 'service access lost'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
