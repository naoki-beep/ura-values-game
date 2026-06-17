-- ============================================================
-- 裏価値観ゲーム / 開始フロー＋罰ゲーム設定（v2スキーマ対応）
--
-- ここで用意する関数:
--   create_session  : 主催が部屋を作る（コード/主催トークン発行・自分もplayer化）
--   join_session    : 参加者がコードで入室（匿名uidでplayer化）
--   start_session   : 席割りを確定して「配り」を行う（各卓に山札・各自に手札5枚）
--   set_trap        : 罰ゲームの罠を1枚仕込む（本人のみ。全員揃うと自動でプレイ開始）
--   begin_play      : 主催が手動でプレイ開始（設定フェーズを締める保険）
--
--   手番処理(play_move)・終了(finish_session)は game-play.sql 側。
--
-- 状態遷移(sessions.status):
--   lobby → (start_session) → 罰ゲームON:'trapping' / OFF:'playing' → 'done'
--   game_tables.status: 罰ゲームONは 'setup' で生成 → 全員罠設定で 'playing'
--   （play_move は status='playing' 以外を弾くので、設定中は手番が進まない）
-- ============================================================

create extension if not exists pgcrypto;  -- gen_random_uuid / gen_random_bytes

-- ------------------------------------------------------------
-- 補助: jsonb配列のスライス（0始まりオフセットから count 件）
-- ------------------------------------------------------------
create or replace function jsonb_slice(arr jsonb, p_start int, p_count int)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(value order by ord), '[]'::jsonb)
  from jsonb_array_elements_text(arr) with ordinality as t(value, ord)
  where ord > p_start and ord <= p_start + p_count;
$$;

-- ------------------------------------------------------------
-- 補助: 一意な参加コード（紛らわしい文字を除外した5桁）
-- ------------------------------------------------------------
create or replace function gen_code()
returns text language plpgsql as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text;
begin
  loop
    c := '';
    for i in 1..5 loop c := c || substr(a, 1 + floor(random()*length(a))::int, 1); end loop;
    perform 1 from sessions where code = c;
    if not found then return c; end if;
  end loop;
end; $$;

-- ------------------------------------------------------------
-- create_session: 主催が部屋を作る
--   返り値: sessionId / code / hostToken / playerId
--   hostToken は主催端末だけが保持し、start/finish 等の認可に使う。
-- ------------------------------------------------------------
create or replace function create_session(
  p_deck_key     text,
  p_penalty      boolean,
  p_table_target int,
  p_name         text
)
returns jsonb language plpgsql security definer set search_path = public as $$
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

-- ------------------------------------------------------------
-- join_session: 参加者がコードで入室（ロビー中のみ）
--   同じ端末の再入室は名前更新＆再接続扱い（重複席は作らない）
-- ------------------------------------------------------------
create or replace function join_session(p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_sid uuid; v_status text; v_pid uuid;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select id, status into v_sid, v_status from sessions where code = upper(p_code);
  if not found then raise exception 'room not found'; end if;
  if v_status <> 'lobby' then raise exception 'already started'; end if;
  insert into players(session_id, user_id, name)
    values (v_sid, v_uid, coalesce(nullif(p_name,''),'ゲスト'))
    on conflict (session_id, user_id)
      do update set name = excluded.name, connected = true, last_seen = now()
    returning id into v_pid;
  return jsonb_build_object('sessionId',v_sid,'playerId',v_pid);
end; $$;

-- ------------------------------------------------------------
-- start_session: 席割りを確定して配る
--   p_cards      : デッキの全カード（Edge Function が DECKS[deckKey].cards を渡す）
--   p_assignment : 卓割り [[playerId, playerId, ...], [ ... ], ...]
--                  各卓 2〜8人。卓ごとに山札をシャッフルして各自に5枚配り、
--                  残りをその卓の山札(table_piles)にする。
-- ------------------------------------------------------------
create or replace function start_session(
  p_session    uuid,
  p_host_token text,
  p_cards      jsonb,
  p_assignment jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ok boolean; v_pen boolean; v_status text;
  ti int; s int; k int; ptr int;
  members jsonb; tdeck jsonb; pile jsonb; gtid uuid; pid uuid;
begin
  -- 主催認可
  select exists(select 1 from session_secrets where session_id=p_session and host_token=p_host_token) into v_ok;
  if not v_ok then raise exception 'not host'; end if;

  select penalty_mode, status into v_pen, v_status from sessions where id=p_session;
  if v_status <> 'lobby' then raise exception 'already started'; end if;
  if jsonb_array_length(p_assignment) < 1 then raise exception 'no tables'; end if;

  for ti in 0 .. jsonb_array_length(p_assignment)-1 loop
    members := p_assignment -> ti;
    k := jsonb_array_length(members);
    if k < 2 or k > 8 then raise exception 'table % must have 2..8 players', ti; end if;
    if k*5 > jsonb_array_length(p_cards) then raise exception 'deck too small for table %', ti; end if;

    -- この卓専用にシャッフル
    select jsonb_agg(value order by random()) into tdeck
      from jsonb_array_elements_text(p_cards) as t(value);

    ptr := 0;
    for s in 0 .. k-1 loop
      pid := (members ->> s)::uuid;
      update players set table_index = ti, seat = s
        where id = pid and session_id = p_session;
      insert into player_hands(player_id, session_id, user_id, hand)
        select pid, p_session, p.user_id, jsonb_slice(tdeck, ptr, 5)
          from players p where p.id = pid
        on conflict (player_id) do update set hand = excluded.hand, updated_at = now();
      ptr := ptr + 5;
    end loop;

    pile := jsonb_slice(tdeck, ptr, jsonb_array_length(tdeck) - ptr);

    insert into game_tables(session_id, table_index, field, turn_seat, pile_count, status, version)
      values (p_session, ti, '[]'::jsonb, 0, jsonb_array_length(pile),
              case when v_pen then 'setup' else 'playing' end, 0)
      returning id into gtid;
    insert into table_piles(table_id, session_id, pile) values (gtid, p_session, pile);
  end loop;

  update sessions set status = case when v_pen then 'trapping' else 'playing' end
    where id = p_session;

  return jsonb_build_object('ok', true, 'phase', case when v_pen then 'trapping' else 'playing' end);
end; $$;

-- ------------------------------------------------------------
-- set_trap: 罰ゲームの罠を1枚仕込む（本人のみ・設定フェーズ中）
--   全員が仕込み終わったら自動で 'playing' に切り替える。
-- ------------------------------------------------------------
create or replace function set_trap(p_session uuid, p_card text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_pen boolean; v_status text; v_pid uuid; v_all boolean := false;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  select penalty_mode, status into v_pen, v_status from sessions where id = p_session;
  if not v_pen then raise exception 'not a penalty room'; end if;
  if v_status <> 'trapping' then raise exception 'not in trap-setting phase'; end if;

  select id into v_pid from players where session_id = p_session and user_id = v_uid;
  if not found then raise exception 'player not in session'; end if;

  insert into penalty_traps(session_id, player_id, user_id, card)
    values (p_session, v_pid, v_uid, p_card)
    on conflict (session_id, player_id) do update set card = excluded.card, created_at = now();

  -- 全員ぶん揃ったらプレイ開始
  if (select count(*) from penalty_traps where session_id = p_session)
     >= (select count(*) from players where session_id = p_session) then
    update game_tables set status = 'playing' where session_id = p_session and status = 'setup';
    update sessions set status = 'playing' where id = p_session and status = 'trapping';
    v_all := true;
  end if;

  return jsonb_build_object('ok', true, 'allSet', v_all);
end; $$;

-- ------------------------------------------------------------
-- begin_play: 主催が手動でプレイ開始（設定フェーズの締め・保険）
--   罠未設定の人がいてもOK（その人は仕掛けなしで参加）
-- ------------------------------------------------------------
create or replace function begin_play(p_session uuid, p_host_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ok boolean;
begin
  select exists(select 1 from session_secrets where session_id=p_session and host_token=p_host_token) into v_ok;
  if not v_ok then raise exception 'not host'; end if;
  update game_tables set status='playing' where session_id=p_session and status='setup';
  update sessions set status='playing' where id=p_session and status='trapping';
  return jsonb_build_object('ok', true);
end; $$;

-- ------------------------------------------------------------
-- 実行権限（authenticated＝匿名JWTから呼ぶ）
-- ------------------------------------------------------------
grant execute on function create_session(text,boolean,int,text) to authenticated;
grant execute on function join_session(text,text)               to authenticated;
grant execute on function start_session(uuid,text,jsonb,jsonb)   to authenticated;
grant execute on function set_trap(uuid,text)                    to authenticated;
grant execute on function begin_play(uuid,text)                  to authenticated;

-- ============================================================
-- Edge Function / クライアントからの呼び出し例（要・匿名サインイン）
-- ------------------------------------------------------------
-- 主催:
--   const { data } = await supa.rpc('create_session', {
--     p_deck_key:'sexDeep', p_penalty:true, p_table_target:6, p_name:'なお' });
--   // data.code をQR化、data.hostToken は端末に保存
--
-- 参加者:
--   await supa.rpc('join_session', { p_code:'Y2AK3', p_name:'Ken' });
--
-- 主催が席割り確定→配り（DECKSはアプリ側が持っている）:
--   await supa.rpc('start_session', {
--     p_session: sid, p_host_token: hostToken,
--     p_cards: DECKS[deckKey].cards,
--     p_assignment: [[pidA,pidB,pidC],[pidD,pidE,...]] });  // 各卓2〜8人
--
-- 罰ゲーム（trapping フェーズ）:
--   await supa.rpc('set_trap', { p_session: sid, p_card:'見栄っ張り' });
--   // 全員設定で自動 'playing'。主催が締めるなら begin_play(sid, hostToken)
--
-- 以降は game-play.sql の play_move を手番ごとに呼ぶ。
-- ============================================================
