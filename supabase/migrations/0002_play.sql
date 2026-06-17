-- ============================================================
-- 裏価値観ゲーム / 手番処理＋終了ルール（v2スキーマ対応）
--
-- 設計の要点:
--  * 同時接続で競合が起きるため、game_tables 行を FOR UPDATE でロックし
--    「検証 → 手札/山札/場の更新 → 終了判定」を1トランザクションで原子的に行う。
--  * version（連番）で二重送信/古い画面からの操作を弾く。
--  * 終了ルール = プレビューと同一:
--      山札が尽きたら即終了ではなく、全員がもう1ターンずつ。
--      最終ターンは「捨ててから場の1枚を拾う（自分の捨て札もOK）」で山札は使わない。
--      全員の最終ターンが済んだら結果発表（final_hand を公開）。
--  * SECURITY DEFINER だが auth.uid() は呼び出し元JWTのものが入る。
--    → ユーザーの匿名JWTでこの関数を実行させ、関数内でルールを強制する。
-- ============================================================

-- ------------------------------------------------------------
-- 補助: jsonb配列(文字列)から最初に一致した1件だけ取り除く
-- ------------------------------------------------------------
create or replace function jsonb_remove_first(arr jsonb, val text)
returns jsonb
language sql
immutable
as $$
  with e as (
    select value, ord
    from jsonb_array_elements_text(arr) with ordinality as t(value, ord)
  ),
  hit as ( select min(ord) as ord from e where value = val )
  select coalesce(
           jsonb_agg(e.value order by e.ord)
             filter (where e.ord is distinct from (select ord from hit)),
           '[]'::jsonb
         )
  from e;
$$;

-- ------------------------------------------------------------
-- 手番を1つ進める / 終了判定（プレビュー advance() と同一ロジック）
--   返り値: 卓が終了したら true
-- ------------------------------------------------------------
create or replace function play_move(
  p_session     uuid,
  p_table_index int,
  p_version     bigint,
  p_discard     text,                 -- 捨てる札（手札にある必要あり）
  p_draw_kind   text,                 -- 'pile' | 'field'
  p_draw_card   text default null     -- 'field' のとき拾う札（最終ターンは自分の捨て札も可）
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
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  -- 1) 卓をロック（同時手番を直列化）
  select * into gt from game_tables
   where session_id = p_session and table_index = p_table_index
   for update;
  if not found then raise exception 'table not found'; end if;
  if gt.status <> 'playing' then raise exception 'table not playing'; end if;

  -- 2) 古い画面/二重送信を弾く
  if gt.version <> p_version then
    raise exception 'stale version (refetch and retry)';
  end if;

  -- 3) 操作者の特定と手番チェック
  select * into pl from players
   where session_id = p_session and user_id = v_uid;
  if not found then raise exception 'player not in session'; end if;
  if pl.table_index is distinct from p_table_index then raise exception 'wrong table'; end if;
  if pl.seat is distinct from gt.turn_seat then raise exception 'not your turn'; end if;

  select count(*) into v_n from players
   where session_id = p_session and table_index = p_table_index;

  -- 4) 手札ロード＆捨て札の検証
  select hand into v_hand from player_hands where player_id = pl.id for update;
  if v_hand is null then raise exception 'hand missing'; end if;
  if not (v_hand ? p_discard) then raise exception 'discard not in hand'; end if;

  v_field := gt.field;
  v_final := (gt.pile_count = 0);   -- 山札が尽きている＝最終ターン

  -- 5) 捨てて拾う
  v_hand := jsonb_remove_first(v_hand, p_discard);

  if v_final then
    -- 最終ターン: 捨て札を先に場へ → 場から1枚（自分の捨て札も対象）
    v_field := v_field || to_jsonb(p_discard);
    if p_draw_card is null or not (v_field ? p_draw_card) then
      raise exception 'final turn must pick an existing field card';
    end if;
    v_drew  := p_draw_card;
    v_field := jsonb_remove_first(v_field, p_draw_card);
    v_hand  := v_hand || to_jsonb(v_drew);
    -- pile_count は 0 のまま
  else
    if p_draw_kind = 'pile' then
      -- 山札の本体（秘密）から先頭を1枚（行ロック）
      select pile into v_pile from table_piles where table_id = gt.id for update;
      if v_pile is null or jsonb_array_length(v_pile) = 0 then
        raise exception 'pile empty';
      end if;
      v_drew := v_pile ->> 0;
      v_pile := v_pile - 0;
      update table_piles set pile = v_pile where table_id = gt.id;
      gt.pile_count := jsonb_array_length(v_pile);
      v_hand  := v_hand || to_jsonb(v_drew);
      v_field := v_field || to_jsonb(p_discard);   -- 捨て札は引いた後に場へ（同一ターン回収不可）
    elsif p_draw_kind = 'field' then
      if p_draw_card is null or not (v_field ? p_draw_card) then
        raise exception 'field card not available';
      end if;
      v_drew  := p_draw_card;
      v_field := jsonb_remove_first(v_field, p_draw_card);
      v_hand  := v_hand || to_jsonb(v_drew);
      v_field := v_field || to_jsonb(p_discard);
    else
      raise exception 'invalid draw kind';
    end if;
  end if;

  -- 6) 罰ゲーム判定（#2 で本実装）: 引いた札が誰かの罠なら発動イベントを立てる
  --    仕掛け人も公開する仕様。最初から持っていた札は draw ではないのでここに来ない。
  if (select penalty_mode from sessions where id = p_session) then
    select pt_user.name into v_trap_setter
      from penalty_traps tp
      join players pt_user on pt_user.id = tp.player_id
     where tp.session_id = p_session and tp.card = v_drew
     limit 1;
  end if;

  -- 7) 手札を保存
  update player_hands set hand = v_hand, updated_at = now() where player_id = pl.id;

  -- 8) 終了ルール（advance）
  if gt.pile_count = 0 and gt.final_turns_left is null then
    gt.final_turns_left := v_n;                 -- これから全員が最後の1ターンずつ
  elsif gt.final_turns_left is not null then
    gt.final_turns_left := gt.final_turns_left - 1;
  end if;

  if gt.final_turns_left is not null and gt.final_turns_left <= 0 then
    v_done := true;
    gt.status := 'done';
  else
    gt.turn_seat := (gt.turn_seat + 1) % v_n;
  end if;

  -- 9) 卓の共有状態を更新（version++・直近イベント）
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

  -- 10) 卓終了なら結果発表（手札を final_hand に公開）
  if v_done then
    update players p
       set final_hand = ph.hand
      from player_hands ph
     where ph.player_id = p.id
       and p.session_id = p_session
       and p.table_index = p_table_index;

    -- 全卓が終わっていればセッションも done に
    if not exists (
      select 1 from game_tables
       where session_id = p_session and status <> 'done'
    ) then
      update sessions set status = 'done' where id = p_session;
    end if;
  end if;

  -- 11) 結果を返す（自分の引いた札・新versionなど。手札自体は player_hands 購読で届く）
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

-- ------------------------------------------------------------
-- 主催が途中終了（時間切れ）: その場の手札を確定して結果発表
-- ------------------------------------------------------------
create or replace function finish_session(p_session uuid, p_host_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_ok boolean;
begin
  select exists(
    select 1 from session_secrets
     where session_id = p_session and host_token = p_host_token
  ) into v_ok;
  if not v_ok then raise exception 'not host'; end if;

  update players p
     set final_hand = ph.hand
    from player_hands ph
   where ph.player_id = p.id and p.session_id = p_session;

  update game_tables set status = 'done', updated_at = now()
   where session_id = p_session;
  update sessions set status = 'done' where id = p_session;

  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 実行権限: 匿名JWT（authenticated ロール）から呼べるようにする。
--   関数内でルールを強制するので、テーブルへの直接権限は与えない。
-- ------------------------------------------------------------
grant execute on function play_move(uuid,int,bigint,text,text,text) to authenticated;
grant execute on function finish_session(uuid,text)               to authenticated;

-- ============================================================
-- Edge Function 側はこれだけ（認証済みクライアントで RPC を呼ぶ）:
--
--   // supabase/functions/game/index.ts （play アクション抜粋）
--   const supa = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
--     global: { headers: { Authorization: req.headers.get('Authorization')! } }
--   });
--   const { data, error } = await supa.rpc('play_move', {
--     p_session: body.sessionId, p_table_index: body.tableIndex,
--     p_version: body.version,  p_discard: body.discard,
--     p_draw_kind: body.drawKind, p_draw_card: body.drawCard ?? null
--   });
--   // error?.message === 'stale version ...' のときはクライアントで再取得→再送
--
--   ※ 直接 supabase.rpc('play_move', …) をフロントから呼んでもよい（関数が守る）。
--     Edge Function を挟むのは、ログ/レート制限/将来の課金チェックを足すため。
-- ============================================================
