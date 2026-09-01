-- =============================================================
-- 밀양인더스트릿 여행자 가이드 — Supabase 스키마 v1
-- Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run 하세요.
-- =============================================================

create extension if not exists pgcrypto;

-- ---------- 설정 ----------
create table if not exists app_settings (
  key text primary key,
  value text not null
);

insert into app_settings (key, value) values
  ('submission_deadline', '2026-11-06'),      -- 최초 제출 마감 (여행종료+1주)
  ('resubmission_deadline', '2026-11-13'),    -- 반려 후 재제출 마감 (+2주)
  ('service_open', 'true')                    -- false 로 바꾸면 접수 마감 화면
on conflict (key) do nothing;

-- ---------- 참가자 ----------
create table if not exists participants (
  id uuid primary key default gen_random_uuid(),
  phone text unique not null,                 -- 01000000000 (숫자만 저장)
  name text not null,
  org text not null,                          -- 소속 (기업 대상, 필수)
  pin_hash text not null,
  must_change_pin boolean not null default false,  -- 관리자 초기화 후 true
  session_token uuid,
  status text not null default 'joined',      -- joined | drafting | submitted | rejected | approved
  consent_privacy boolean not null default false,  -- 개인정보 수집·이용(5년)
  consent_photo boolean not null default false,    -- 얼굴사진 별도 동의
  consent_duty boolean not null default false,     -- 증빙 의무·환수 확인
  consented_at timestamptz,
  dtc_status text,                            -- 'has'(이미 가입) | 'guided'(안내 확인)
  survey jsonb,
  submitted_at timestamptz,
  reject_reason text,
  reviewed_at timestamptz,
  deadline_override date,                     -- 관리자 개별 기간 연장
  created_at timestamptz not null default now()
);

-- ---------- 방문 증빙 ----------
create table if not exists visits (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants(id) on delete cascade,
  merchant_name text not null,
  merchant_category text,
  merchant_region text,
  photo1_path text,
  photo2_path text,
  receipt1_path text,
  receipt2_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (participant_id, merchant_name)      -- 같은 업체 중복 제출 차단
);

-- ---------- RLS: 익명 직접 접근 전면 차단, 관리자(authenticated) 전권 ----------
alter table participants enable row level security;
alter table visits enable row level security;
alter table app_settings enable row level security;

create policy admin_all_participants on participants
  for all to authenticated using (true) with check (true);
create policy admin_all_visits on visits
  for all to authenticated using (true) with check (true);
create policy admin_all_settings on app_settings
  for all to authenticated using (true) with check (true);
create policy anon_read_settings on app_settings
  for select to anon using (true);

-- =============================================================
-- RPC 함수 (익명 사용자는 아래 함수로만 데이터 접근)
-- =============================================================

-- 내부: 토큰으로 참가자 찾기
create or replace function _p_by_token(p_token uuid)
returns participants language sql security definer as $$
  select * from participants where session_token = p_token and session_token is not null;
$$;

-- 가입
create or replace function fn_signup(p_phone text, p_name text, p_org text, p_pin text)
returns json language plpgsql security definer as $$
declare v_token uuid := gen_random_uuid(); v_id uuid;
begin
  if length(regexp_replace(p_phone,'\D','','g')) < 10 then
    return json_build_object('error','invalid_phone');
  end if;
  if p_pin !~ '^\d{6}$' then return json_build_object('error','invalid_pin'); end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_org),'') = '' then
    return json_build_object('error','missing_fields');
  end if;
  insert into participants (phone, name, org, pin_hash, session_token, status)
  values (regexp_replace(p_phone,'\D','','g'), trim(p_name), trim(p_org),
          crypt(p_pin, gen_salt('bf')), v_token, 'joined')
  returning id into v_id;
  return json_build_object('token', v_token);
exception when unique_violation then
  return json_build_object('error','phone_exists');
end $$;

-- 로그인
create or replace function fn_login(p_phone text, p_pin text)
returns json language plpgsql security definer as $$
declare v participants; v_token uuid := gen_random_uuid();
begin
  select * into v from participants where phone = regexp_replace(p_phone,'\D','','g');
  if v.id is null then return json_build_object('error','not_found'); end if;
  if v.pin_hash <> crypt(p_pin, v.pin_hash) then
    return json_build_object('error','wrong_pin');
  end if;
  update participants set session_token = v_token where id = v.id;
  return json_build_object('token', v_token, 'must_change_pin', v.must_change_pin);
end $$;

-- 내 상태 + 방문 목록
create or replace function fn_me(p_token uuid)
returns json language plpgsql security definer as $$
declare v participants;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  return json_build_object(
    'participant', json_build_object(
      'name', v.name, 'org', v.org, 'phone', v.phone, 'status', v.status,
      'consent_privacy', v.consent_privacy, 'consent_photo', v.consent_photo,
      'consent_duty', v.consent_duty, 'dtc_status', v.dtc_status,
      'must_change_pin', v.must_change_pin, 'reject_reason', v.reject_reason,
      'submitted_at', v.submitted_at, 'survey_done', (v.survey is not null),
      'deadline_override', v.deadline_override),
    'visits', coalesce((select json_agg(json_build_object(
      'id', id, 'merchant_name', merchant_name, 'merchant_category', merchant_category,
      'merchant_region', merchant_region, 'photo1_path', photo1_path, 'photo2_path', photo2_path,
      'receipt1_path', receipt1_path, 'receipt2_path', receipt2_path)
      order by created_at)
      from visits where participant_id = v.id), '[]'::json));
end $$;

-- 동의 저장
create or replace function fn_set_consents(p_token uuid, p_privacy boolean, p_photo boolean, p_duty boolean)
returns json language plpgsql security definer as $$
declare v participants;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  update participants set consent_privacy = p_privacy, consent_photo = p_photo,
    consent_duty = p_duty, consented_at = now(),
    status = case when status = 'joined' then 'drafting' else status end
  where id = v.id;
  return json_build_object('ok', true);
end $$;

-- 주민증 상태
create or replace function fn_set_dtc(p_token uuid, p_status text)
returns json language plpgsql security definer as $$
declare v participants;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  update participants set dtc_status = p_status where id = v.id;
  return json_build_object('ok', true);
end $$;

-- 방문 임시저장 (생성/수정)
create or replace function fn_upsert_visit(p_token uuid, p_visit json)
returns json language plpgsql security definer as $$
declare v participants; v_id uuid;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  if v.status in ('submitted','approved') then return json_build_object('error','locked'); end if;
  v_id := nullif(p_visit->>'id','')::uuid;
  if v_id is null then
    insert into visits (participant_id, merchant_name, merchant_category, merchant_region,
      photo1_path, photo2_path, receipt1_path, receipt2_path)
    values (v.id, p_visit->>'merchant_name', p_visit->>'merchant_category', p_visit->>'merchant_region',
      p_visit->>'photo1_path', p_visit->>'photo2_path', p_visit->>'receipt1_path', p_visit->>'receipt2_path')
    returning id into v_id;
  else
    update visits set merchant_name = p_visit->>'merchant_name',
      merchant_category = p_visit->>'merchant_category', merchant_region = p_visit->>'merchant_region',
      photo1_path = p_visit->>'photo1_path', photo2_path = p_visit->>'photo2_path',
      receipt1_path = p_visit->>'receipt1_path', receipt2_path = p_visit->>'receipt2_path',
      updated_at = now()
    where id = v_id and participant_id = v.id;
  end if;
  update participants set status = 'drafting' where id = v.id and status = 'joined';
  return json_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  return json_build_object('error','duplicate_merchant');
end $$;

-- 방문 삭제
create or replace function fn_delete_visit(p_token uuid, p_visit_id uuid)
returns json language plpgsql security definer as $$
declare v participants;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  if v.status in ('submitted','approved') then return json_build_object('error','locked'); end if;
  delete from visits where id = p_visit_id and participant_id = v.id;
  return json_build_object('ok', true);
end $$;

-- 제출 (마감·조건 검증 포함)
create or replace function fn_submit(p_token uuid, p_survey jsonb)
returns json language plpgsql security definer as $$
declare v participants; n int; v_deadline date; v_open text;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  select value into v_open from app_settings where key = 'service_open';
  if v_open <> 'true' then return json_build_object('error','closed'); end if;

  -- 마감: 개별 연장 > (반려자는 재제출 마감 / 그 외 최초 마감)
  if v.deadline_override is not null then
    v_deadline := v.deadline_override;
  elsif v.status = 'rejected' then
    select value::date into v_deadline from app_settings where key = 'resubmission_deadline';
  else
    select value::date into v_deadline from app_settings where key = 'submission_deadline';
  end if;
  if current_date > v_deadline then return json_build_object('error','deadline_passed'); end if;

  select count(*) into n from visits
    where participant_id = v.id
      and photo1_path is not null and photo2_path is not null and receipt1_path is not null;
  if n < 2 then return json_build_object('error','need_two_visits'); end if;

  update participants set status = 'submitted', submitted_at = now(),
    survey = coalesce(p_survey, survey), reject_reason = null
  where id = v.id;
  return json_build_object('ok', true);
end $$;

-- 핀 변경 (관리자 초기화 후 / 본인 변경)
create or replace function fn_change_pin(p_token uuid, p_new_pin text)
returns json language plpgsql security definer as $$
declare v participants;
begin
  v := _p_by_token(p_token);
  if v.id is null then return json_build_object('error','bad_token'); end if;
  if p_new_pin !~ '^\d{6}$' then return json_build_object('error','invalid_pin'); end if;
  update participants set pin_hash = crypt(p_new_pin, gen_salt('bf')), must_change_pin = false
  where id = v.id;
  return json_build_object('ok', true);
end $$;

-- 익명 실행 권한
grant execute on function fn_signup(text,text,text,text) to anon;
grant execute on function fn_login(text,text) to anon;
grant execute on function fn_me(uuid) to anon;
grant execute on function fn_set_consents(uuid,boolean,boolean,boolean) to anon;
grant execute on function fn_set_dtc(uuid,text) to anon;
grant execute on function fn_upsert_visit(uuid,json) to anon;
grant execute on function fn_delete_visit(uuid,uuid) to anon;
grant execute on function fn_submit(uuid,jsonb) to anon;
grant execute on function fn_change_pin(uuid,text) to anon;
revoke execute on function _p_by_token(uuid) from anon;

-- =============================================================
-- 스토리지: 'evidence' 버킷(비공개)을 대시보드에서 만든 뒤 아래 실행
-- =============================================================
-- 익명: 업로드만 가능(열람·목록 불가). 관리자: 전체 열람.
create policy evidence_anon_insert on storage.objects
  for insert to anon with check (bucket_id = 'evidence');
create policy evidence_admin_read on storage.objects
  for select to authenticated using (bucket_id = 'evidence');
create policy evidence_admin_delete on storage.objects
  for delete to authenticated using (bucket_id = 'evidence');
