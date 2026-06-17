-- ============================================================
-- 裏価値観ゲーム / Supabase スキーマ v2
-- 目的: 「隠す情報（手札・山札・トラップ）」を物理的に分離し、
--        RLS で SELECT とリアルタイム配信の両方を遮断する。
--
-- 本人特定: Supabase の「匿名サインイン」を使う。
--   各端末は supabase.auth.signInAnonymously() で auth.uid() を取得。
--   players.user_id にそれを保存し、RLS の鍵にする。
--   （Dashboard > Authentication > Sign In / Providers で Anonymous を ON）
--
-- 書き込み: クライアントは一切 INSERT/UPDATE しない。
--   すべて Edge Function（service_role）経由。service_role は RLS を貫通する。
--   よって下記ポリシーは基本「読み取りだけ」を定義し、書き込みは付けない＝拒否。
-- ============================================================

-- （初回マイグレーション。既存DBに本番データがある場合は適用前にリセット方針を検討）

-- ------------------------------------------------------------
-- sessions: 部屋。メンバーだけが見られる（コードは Edge Function 経由で参加）
-- ------------------------------------------------------------
create table sessions (
  id            uuid primary key default gen_random_uuid(),
  code          text unique not null,           -- 参加コード（QR/手入力）
  deck_key      text not null,                  -- 'ura' | 'work' | ... | 'sexDeep'
  penalty_mode  boolean not null default false, -- 罰ゲームモード（18禁デッキのみ true になる想定）
  status        text not null default 'lobby',  -- 'lobby' | 'playing' | 'done'
  table_target  int  not null default 6,        -- 1卓の目標人数（2〜8）
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------
-- players: 公開して良い名簿情報のみ。手札はここに置かない。
--   final_hand は「結果発表」時だけ Edge Function が書き込む（それまで null）
-- ------------------------------------------------------------
create table players (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references sessions(id) on delete cascade,
  user_id      uuid not null,                   -- 端末の auth.uid()
  name         text not null,
  table_index  int,                             -- 割り当てられた卓（席割り後に確定）
  seat         int,                             -- 卓内の席番号 0..K-1（手番判定に使用）
  is_host      boolean not null default false,
  connected    boolean not null default true,
  final_hand   jsonb,                           -- 結果発表時のみ公開（最後の5枚）
  last_seen    timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  unique (session_id, user_id)                  -- 1端末1席
);
create index players_session_idx on players(session_id);
create index players_table_idx   on players(session_id, table_index);

-- ------------------------------------------------------------
-- player_hands: 手札（秘密）。1人1行。本人しか SELECT できない。
--   行ごとに user_id で絞るので、他人の手札は配信もされない。
-- ------------------------------------------------------------
create table player_hands (
  player_id    uuid primary key references players(id) on delete cascade,
  session_id   uuid not null references sessions(id) on delete cascade,
  user_id      uuid not null,                   -- RLS 用（= 所有者）
  hand         jsonb not null default '[]',     -- 例: ["わがまま","見栄っ張り",...]
  updated_at   timestamptz not null default now()
);
create index player_hands_session_idx on player_hands(session_id);

-- ------------------------------------------------------------
-- game_tables: 卓ごとの「共有して良い」状態。卓のメンバーが見られる。
--   山札は枚数(pile_count)だけ。中身は持たない。
--   last_event: 直近の出来事（読み上げ/罰ゲーム発動）を全員に配信するための一時情報。
-- ------------------------------------------------------------
create table game_tables (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid not null references sessions(id) on delete cascade,
  table_index      int  not null,
  field            jsonb not null default '[]', -- 場（捨て札・表向き＝公開OK）
  turn_seat        int  not null default 0,     -- 手番の席番号
  pile_count       int  not null default 0,     -- 山札の「残り枚数」だけ
  final_turns_left int,                          -- null=通常 / 山札消滅後に人数をセット
  status           text not null default 'playing', -- 'playing' | 'done'
  last_event       jsonb,                         -- {type:'draw'|'penalty', ...}
  version          bigint not null default 0,     -- 二重送信/競合検出（楽観ロック）
  updated_at       timestamptz not null default now(),
  unique (session_id, table_index)
);
create index game_tables_session_idx on game_tables(session_id);

-- ------------------------------------------------------------
-- table_piles: 山札の本体（秘密・順序つき）。誰も SELECT できない。
--   RLS を ON にしてポリシーを一切作らない＝authenticated は全拒否。
--   Edge Function(service_role) だけが触る。Realtime にも載せない。
-- ------------------------------------------------------------
create table table_piles (
  table_id     uuid primary key references game_tables(id) on delete cascade,
  session_id   uuid not null references sessions(id) on delete cascade,
  pile         jsonb not null default '[]'       -- 残り山札（順序つき・秘密）
);

-- ------------------------------------------------------------
-- penalty_traps: 各自が仕込む罰カード（発動まで秘密）。本人だけ自分の分を見られる。
--   発動判定は Edge Function が全行を読んで行う（service_role）。
-- ------------------------------------------------------------
create table penalty_traps (
  session_id   uuid not null references sessions(id) on delete cascade,
  player_id    uuid not null references players(id) on delete cascade,
  user_id      uuid not null,                   -- RLS 用（= 仕掛け人本人）
  card         text not null,                   -- 仕込んだ札
  created_at   timestamptz not null default now(),
  primary key (session_id, player_id)
);

-- ------------------------------------------------------------
-- session_secrets: 主催トークン（host_token）。誰も SELECT できない。
--   Edge Function が主催操作（開始/終了/席割り）の認可に使う。
-- ------------------------------------------------------------
create table session_secrets (
  session_id   uuid primary key references sessions(id) on delete cascade,
  host_token   text not null
);

-- ============================================================
-- メンバー判定ヘルパー（RLS の再帰を避けるため SECURITY DEFINER）
--   players を直接読み（RLSを貫通）、呼び出し元の auth.uid() が
--   その session のメンバーかどうかだけ返す。
-- ============================================================
create or replace function is_session_member(sid uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from players p
    where p.session_id = sid
      and p.user_id = auth.uid()
  );
$$;

-- ============================================================
-- RLS 有効化
-- ============================================================
alter table sessions        enable row level security;
alter table players         enable row level security;
alter table player_hands    enable row level security;
alter table game_tables     enable row level security;
alter table table_piles     enable row level security; -- ポリシー無し＝全拒否
alter table penalty_traps   enable row level security;
alter table session_secrets enable row level security; -- ポリシー無し＝全拒否

-- ------------------------------------------------------------
-- 読み取りポリシー（書き込みポリシーは作らない＝service_role 以外は書けない）
-- ------------------------------------------------------------

-- 部屋: メンバーだけが見られる
create policy sessions_select_member on sessions
  for select to authenticated
  using (is_session_member(id));

-- 名簿: 同じ部屋のメンバー同士は見える（手札は別テーブルなので漏れない）
create policy players_select_member on players
  for select to authenticated
  using (is_session_member(session_id));

-- 手札: 本人の行だけ（他人の手札は配信もされない）
create policy hands_select_self on player_hands
  for select to authenticated
  using (user_id = auth.uid());

-- 卓の共有状態: 同じ部屋のメンバーが見える
create policy tables_select_member on game_tables
  for select to authenticated
  using (is_session_member(session_id));

-- 罠: 本人の分だけ確認できる（発動するまで他人には見えない）
create policy traps_select_self on penalty_traps
  for select to authenticated
  using (user_id = auth.uid());

-- table_piles / session_secrets はポリシー未定義 → authenticated からは常に空。

-- ============================================================
-- Realtime 配信対象（RLS が配信にも効く）
--   秘密テーブル(table_piles, penalty_traps, session_secrets)は載せない。
--   player_hands は載せるが RLS で本人にしか届かない。
-- ============================================================
alter publication supabase_realtime add table sessions;
alter publication supabase_realtime add table players;
alter publication supabase_realtime add table game_tables;
alter publication supabase_realtime add table player_hands;

-- 更新/削除イベントで行の中身を正しく評価できるように
alter table sessions      replica identity full;
alter table players       replica identity full;
alter table game_tables   replica identity full;
alter table player_hands  replica identity full;

-- ============================================================
-- 購読の張り方（クライアント側の指針・メモ）
-- ------------------------------------------------------------
-- 1) 起動時:  await supabase.auth.signInAnonymously()
-- 2) 参加:    Edge Function 'join'(code, name) を呼ぶ → players 行が作られる
-- 3) ロビー中: sessions(id=自分の部屋) と players(session_id=自分の部屋) を購読
--             → 参加者の増加と status='playing' への変化を受信
-- 4) 開始後:  自分の players 行で table_index/seat を知り、
--             game_tables(session_id=部屋, table_index=自分の卓) を購読 ＝ 1卓ぶんだけ
--             player_hands(player_id=自分) を購読 ＝ 自分の手札だけ
-- 5) 手を打つ: Edge Function 'play'(version, ...) を呼ぶ。直接書き込まない。
-- 6) 再接続:  画面復帰時に players(自分)・game_tables(自分の卓)・player_hands(自分) を
--             取り直して購読し直す。user_id は匿名認証で同一に保たれる。
--
-- ※ 他人の手札・山札の中身・他人の罠は、RLS により取得も配信も発生しない。
-- ※ 1部屋N人 = N接続。Realtime の同時接続数上限はプラン依存なので、
--    セミナー規模を想定するなら本番プランの接続数を確認すること。
-- ============================================================
