-- =============================================================
-- 관리자 기능 추가 SQL (schema.sql 실행 후, 이것도 SQL Editor에서 1회 Run)
-- =============================================================

-- 관리자 핀 초기화: 임시 핀을 걸고, 사용자가 다음 로그인 때 새 핀을 강제 설정
create or replace function fn_admin_reset_pin(p_participant_id uuid, p_temp_pin text)
returns json language plpgsql security definer as $$
begin
  if auth.uid() is null then return json_build_object('error','not_admin'); end if;
  if p_temp_pin !~ '^\d{6}$' then return json_build_object('error','invalid_pin'); end if;
  update participants
     set pin_hash = crypt(p_temp_pin, gen_salt('bf')),
         must_change_pin = true,
         session_token = null
   where id = p_participant_id;
  return json_build_object('ok', true);
end $$;

revoke execute on function fn_admin_reset_pin(uuid, text) from anon;
grant execute on function fn_admin_reset_pin(uuid, text) to authenticated;
