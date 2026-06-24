-- ============================================================
-- 0005: 3つの改善をまとめて適用
--   (1) 再入室(リコネクト): 既存メンバーは進行中でもコードで戻れる
--   (2) 罰カードの最大枚数を主催が選べる（1人あたり 1〜5枚）
--   (3) 捨て札に「誰が捨てたか」を保持（場を {c,by,seat} 形式に）
--
-- ⚠️ 一度適用したマイグレーションは編集しない。修正は新ファイルを追加。
-- ============================================================

-- ------------------------------------------------------------
-- (2) sessions に罰カード枚数。penalty_traps を複数枚対応にする。
-- ------------------------------------------------------------
alter table sessions add column if not exists penalty_count int not null default 1;

alter table penalty_traps drop constraint if exists penalty_traps_pkey;
alter table penalty_traps add constraint penalty_traps_pkey
  primary key (session_id, player_id, card);

-- ------------------------------------------------------------
-- (2) create_session: penalty_count を受け取る（旧4引数版は破棄）
-- ------------------------------------------------------------
drop function if exists create_session(text,boolean,int,text);

create or replace function create_session(
  p_deck_key     text,
  p_penalty      boolean,
  p_table_target int,
  p_name         text,
  p_penalty_count int
)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); v_sid uuid; v_pid uuid; v_code text; v_token text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  v_code  := gen_code();
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into sessions(code, deck_key, penalty_mode, status, table_target, penalty_count)
    values (v_code, p_deck_key, coalesce(p_penalty,false), 'lobby', coalesce(p_table_target,6),
            greatest(1, least(coalesce(p_penalty_count,1), 5)))
    returning id into v_sid;
  insert into session_secrets(session_id, host_token) values (v_sid, v_token);
  insert into players(session_id, user_id, name, is_host)
    values (v_sid, v_uid, coalesce(nullif(p_name,''),'主催'), true)
    returning id into v_pid;
  return jsonb_build_object('sessionId',v_sid,'code',v_code,'hostToken',v_token,'playerId',v_pid);
end; $$;

grant execute on function create_session(text,boolean,int,text,int) to authenticated;

-- ------------------------------------------------------------
-- (1) join_session: 既存メンバーは進行中でも再入室（リコネクト）OK。
--     新規参加は従来どおりロビー中のみ。返り値に status を含める。
-- ------------------------------------------------------------
create or replace function join_session(p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_sid uuid; v_status text; v_pid uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select id, status into v_sid, v_status from sessions where code = upper(p_code);
  if not found then raise exception 'room not found'; end if;

  -- すでにこの部屋のメンバーなら、進行中でも戻れる（リロード復帰）
  select id into v_pid from players where session_id = v_sid and user_id = v_uid;
  if found then
    update players set name = coalesce(nullif(p_name,''), name), connected = true, last_seen = now()
      where id = v_pid;
    return jsonb_build_object('sessionId',v_sid,'playerId',v_pid,'status',v_status,'reconnected',true);
  end if;

  -- 新規参加はロビー中のみ
  if v_status <> 'lobby' then raise exception 'already started'; end if;
  insert into players(session_id, user_id, name)
    values (v_sid, v_uid, coalesce(nullif(p_name,''),'ゲスト'))
    returning id into v_pid;
  return jsonb_build_object('sessionId',v_sid,'playerId',v_pid,'status',v_status,'reconnected',false);
end; $$;

grant execute on function join_session(text,text) to authenticated;

-- ------------------------------------------------------------
-- (2) set_trap: 複数枚（配列）対応。枚数は 1〜penalty_count。
--     旧 set_trap(uuid,text) は破棄。
-- ------------------------------------------------------------
drop function if exists set_trap(uuid,text);

create or replace function set_trap(p_session uuid, p_cards jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_pen boolean; v_status text; v_pid uuid;
        v_max int; v_cnt int; v_all boolean := false;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select penalty_mode, status, coalesce(penalty_count,1)
    into v_pen, v_status, v_max from sessions where id = p_session;
  if not v_pen then raise exception 'not a penalty room'; end if;
  if v_status <> 'trapping' then raise exception 'not in trap-setting phase'; end if;

  select id into v_pid from players where session_id = p_session and user_id = v_uid;
  if not found then raise exception 'player not in session'; end if;

  v_cnt := jsonb_array_length(coalesce(p_cards,'[]'::jsonb));
  if v_cnt < 1 then raise exception 'pick at least one card'; end if;
  if v_cnt > v_max then raise exception 'too many cards (max %)', v_max; end if;

  -- 設定し直し: いったん消してから入れ直す
  delete from penalty_traps where session_id = p_session and player_id = v_pid;
  insert into penalty_traps(session_id, player_id, user_id, card)
    select p_session, v_pid, v_uid, value
      from jsonb_array_elements_text(p_cards) as t(value)
    on conflict (session_id, player_id, card) do nothing;

  -- 全員（最低1枚）設定済みならプレイ開始
  if (select count(distinct player_id) from penalty_traps where session_id = p_session)
     >= (select count(*) from players where session_id = p_session) then
    update game_tables set status = 'playing' where session_id = p_session and status = 'setup';
    update sessions set status = 'playing' where id = p_session and status = 'trapping';
    v_all := true;
  end if;

  return jsonb_build_object('ok', true, 'allSet', v_all);
end; $$;

grant execute on function set_trap(uuid,jsonb) to authenticated;

-- ------------------------------------------------------------
-- (3) 場(field)を {c:札, by:捨てた人, seat:席} の配列にする補助関数
-- ------------------------------------------------------------
-- c=val を持つ要素が場にあるか
create or replace function jsonb_has_c(arr jsonb, val text)
returns boolean language sql immutable as $$
  select exists(
    select 1 from jsonb_array_elements(arr) as e(value)
     where e.value->>'c' = val
  );
$$;

-- c=val の最初の1件だけ取り除く
create or replace function jsonb_remove_first_obj(arr jsonb, val text)
returns jsonb language sql immutable as $$
  with e as (
    select value, ord
    from jsonb_array_elements(arr) with ordinality as t(value, ord)
  ),
  hit as ( select min(ord) as ord from e where e.value->>'c' = val )
  select coalesce(
           jsonb_agg(e.value order by e.ord)
             filter (where e.ord is distinct from (select ord from hit)),
           '[]'::jsonb
         )
  from e;
$$;

-- ------------------------------------------------------------
-- (3) play_move: 場への捨て札を {c,by,seat} で積む。拾うときは c で照合。
--     ※ field 以外のロジックは 0002 と同一。
-- ------------------------------------------------------------
create or replace function play_move(
  p_session     uuid,
  p_table_index int,
  p_version     bigint,
  p_discard     text,
  p_draw_kind   text,
  p_draw_card   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  gt       game_tables%rowtype;
  pl       players%rowtype;
  v_n      int;
  v_hand   jsonb;
  v_field  jsonb;
  v_pile   jsonb;
  v_drew   text;
  v_final  boolean;
  v_done   boolean := false;
  v_trap_setter text;
  v_toss   jsonb;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  select * into gt from game_tables
   where session_id = p_session and table_index = p_table_index
   for update;
  if not found then raise exception 'table not found'; end if;
  if gt.status <> 'playing' then raise exception 'table not playing'; end if;

  if gt.version <> p_version then raise exception 'stale version (refetch and retry)'; end if;

  select * into pl from players where session_id = p_session and user_id = v_uid;
  if not found then raise exception 'player not in session'; end if;
  if pl.table_index is distinct from p_table_index then raise exception 'wrong table'; end if;
  if pl.seat is distinct from gt.turn_seat then raise exception 'not your turn'; end if;

  select count(*) into v_n from players
   where session_id = p_session and table_index = p_table_index;

  select hand into v_hand from player_hands where player_id = pl.id for update;
  if v_hand is null then raise exception 'hand missing'; end if;
  if not (v_hand ? p_discard) then raise exception 'discard not in hand'; end if;

  v_field := gt.field;
  v_final := (gt.pile_count = 0);
  -- 捨て札（誰が捨てたか付き）
  v_toss  := jsonb_build_object('c', p_discard, 'by', pl.name, 'seat', pl.seat);

  v_hand := jsonb_remove_first(v_hand, p_discard);

  if v_final then
    -- 最終ターン: 捨て札を先に場へ → 場から1枚（自分の捨て札も対象）
    v_field := v_field || jsonb_build_array(v_toss);
    if p_draw_card is null or not jsonb_has_c(v_field, p_draw_card) then
      raise exception 'final turn must pick an existing field card';
    end if;
    v_drew  := p_draw_card;
    v_field := jsonb_remove_first_obj(v_field, p_draw_card);
    v_hand  := v_hand || to_jsonb(v_drew);
  else
    if p_draw_kind = 'pile' then
      select pile into v_pile from table_piles where table_id = gt.id for update;
      if v_pile is null or jsonb_array_length(v_pile) = 0 then raise exception 'pile empty'; end if;
      v_drew := v_pile ->> 0;
      v_pile := v_pile - 0;
      update table_piles set pile = v_pile where table_id = gt.id;
      gt.pile_count := jsonb_array_length(v_pile);
      v_hand  := v_hand || to_jsonb(v_drew);
      v_field := v_field || jsonb_build_array(v_toss);   -- 捨て札は引いた後に場へ
    elsif p_draw_kind = 'field' then
      if p_draw_card is null or not jsonb_has_c(v_field, p_draw_card) then
        raise exception 'field card not available';
      end if;
      v_drew  := p_draw_card;
      v_field := jsonb_remove_first_obj(v_field, p_draw_card);
      v_hand  := v_hand || to_jsonb(v_drew);
      v_field := v_field || jsonb_build_array(v_toss);
    else
      raise exception 'invalid draw kind';
    end if;
  end if;

  -- 罰ゲーム判定: 引いた札が誰かの罠なら発動
  if (select penalty_mode from sessions where id = p_session) then
    select pt_user.name into v_trap_setter
      from penalty_traps tp
      join players pt_user on pt_user.id = tp.player_id
     where tp.session_id = p_session and tp.card = v_drew
     limit 1;
  end if;

  update player_hands set hand = v_hand, updated_at = now() where player_id = pl.id;

  if gt.pile_count = 0 and gt.final_turns_left is null then
    gt.final_turns_left := v_n;
  elsif gt.final_turns_left is not null then
    gt.final_turns_left := gt.final_turns_left - 1;
  end if;

  if gt.final_turns_left is not null and gt.final_turns_left <= 0 then
    v_done := true;
    gt.status := 'done';
  else
    gt.turn_seat := (gt.turn_seat + 1) % v_n;
  end if;

  update game_tables set
    field            = v_field,
    pile_count       = gt.pile_count,
    turn_seat        = gt.turn_seat,
    final_turns_left = gt.final_turns_left,
    status           = gt.status,
    version          = gt.version + 1,
    updated_at       = now(),
    last_event       = case
      when v_trap_setter is not null then
        jsonb_build_object('type','penalty','drawerSeat',pl.seat,
                           'drawer',pl.name,'setter',v_trap_setter,'card',v_drew)
      else
        jsonb_build_object('type','discard','seat',pl.seat,'card',p_discard)
    end
  where id = gt.id;

  if v_done then
    update players p
       set final_hand = ph.hand
      from player_hands ph
     where ph.player_id = p.id
       and p.session_id = p_session
       and p.table_index = p_table_index;

    if not exists (
      select 1 from game_tables where session_id = p_session and status <> 'done'
    ) then
      update sessions set status = 'done' where id = p_session;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'drew', v_drew,
    'version', gt.version + 1,
    'finalTurnsLeft', gt.final_turns_left,
    'tableStatus', gt.status,
    'penalty', case when v_trap_setter is not null
                    then jsonb_build_object('drawer',pl.name,'setter',v_trap_setter,'card',v_drew)
                    else null end
  );
end;
$$;

grant execute on function play_move(uuid,int,bigint,text,text,text) to authenticated;
