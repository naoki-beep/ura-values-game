-- ============================================================
-- 修正: create_session の search_path に extensions を追加
-- Supabase では pgcrypto 関数が extensions スキーマにあるため、
-- gen_random_bytes が public スキーマから見えない問題を修正。
-- ============================================================

create or replace function create_session(
  p_deck_key     text,
  p_penalty      boolean,
  p_table_target int,
  p_name         text
)
returns jsonb language plpgsql security definer
set search_path = public, extensions
as $$
declare v_uid uuid := auth.uid(); v_sid uuid; v_pid uuid; v_code text; v_token text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  v_code  := gen_code();
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into sessions(code, deck_key, penalty_mode, status, table_target)
    values (v_code, p_deck_key, coalesce(p_penalty,false), 'lobby', coalesce(p_table_target,6))
    returning id into v_sid;
  insert into session_secrets(session_id, host_token) values (v_sid, v_token);
  insert into players(session_id, user_id, name, is_host)
    values (v_sid, v_uid, coalesce(nullif(p_name,''),'主催'), true)
    returning id into v_pid;
  return jsonb_build_object('sessionId',v_sid,'code',v_code,'hostToken',v_token,'playerId',v_pid);
end; $$;

grant execute on function create_session(text,boolean,int,text) to authenticated;
