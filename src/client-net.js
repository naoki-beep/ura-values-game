// ============================================================
// 裏価値観ゲーム / クライアント配線 (#4)
//   UI（プレビュー画面）を Supabase に接続する薄い層。
//   - 匿名サインインで端末ごとの本人(auth.uid)を確保
//   - 部屋作成/参加、ロビー購読、席割り→開始
//   - 開始後は「自分の卓」と「自分の手札」だけ購読（卓単位に閉じる）
//   - 手番は play_move(RPC) を呼ぶだけ。状態は Realtime で各自に届く
//   - last_event で読み上げ/罰ゲーム演出、再接続で取り直し
//
// 事前準備:
//   1) Supabase Dashboard > Authentication で「Anonymous sign-ins」を ON
//   2) supabase-schema-v2.sql / game-play.sql / game-start.sql を実行済み
//   3) npm i @supabase/supabase-js
// ============================================================

import { createClient } from '@supabase/supabase-js';

export function createGameNet({ url, anonKey }) {
  const supabase = createClient(url, anonKey, {
    auth: { persistSession: true, autoRefreshToken: true },
  });

  // セッションをまたいで保持する最小状態
  const store = {
    userId: null,
    sessionId: null,
    playerId: null,
    hostToken: null,   // 主催のみ
    code: null,
    tableIndex: null,
    seat: null,
    gameTableId: null, // 自分の卓の game_tables.id
    version: 0,        // 楽観ロック用（play 時に送る）
  };
  const channels = {}; // name -> RealtimeChannel

  // ---- localStorage（リロード復帰用） ----
  const LS = 'ura:net';
  const saveLocal = () => localStorage.setItem(LS, JSON.stringify({
    sessionId: store.sessionId, playerId: store.playerId,
    hostToken: store.hostToken, code: store.code,
  }));
  const loadLocal = () => { try { return JSON.parse(localStorage.getItem(LS) || '{}'); } catch { return {}; } };

  // ---- 認証（匿名） ----
  async function ensureAuth() {
    let { data: { session } } = await supabase.auth.getSession();
    if (!session) {
      const { data, error } = await supabase.auth.signInAnonymously();
      if (error) throw error;
      session = data.session;
    }
    store.userId = session.user.id;
    // Realtime にも同じトークンを渡す（player_hands の本人限定配信のため）
    supabase.realtime.setAuth(session.access_token);
    supabase.auth.onAuthStateChange((_e, s) => { if (s?.access_token) supabase.realtime.setAuth(s.access_token); });
    return store.userId;
  }

  // ---- 部屋作成（主催） ----
  async function createRoom({ deckKey, penalty = false, tableTarget = 6, name = '主催' }) {
    await ensureAuth();
    const { data, error } = await supabase.rpc('create_session', {
      p_deck_key: deckKey, p_penalty: penalty, p_table_target: tableTarget, p_name: name,
    });
    if (error) throw error;
    store.sessionId = data.sessionId; store.playerId = data.playerId;
    store.hostToken = data.hostToken; store.code = data.code;
    saveLocal();
    return data; // { sessionId, code, hostToken, playerId }
  }

  // ---- 入室（参加者） ----
  async function joinRoom({ code, name = 'ゲスト' }) {
    await ensureAuth();
    const { data, error } = await supabase.rpc('join_session', { p_code: code, p_name: name });
    if (error) throw error;
    store.sessionId = data.sessionId; store.playerId = data.playerId; store.code = code;
    saveLocal();
    return data; // { sessionId, playerId }
  }

  // ---- ロビー購読（名簿の増減 + 開始の合図） ----
  async function subscribeLobby({ onPlayers, onStatus }) {
    const sid = store.sessionId;
    // 初期取得
    const { data: ps } = await supabase.from('players')
      .select('id,name,is_host,table_index,seat,connected')
      .eq('session_id', sid).order('created_at');
    onPlayers?.(ps || []);
    const { data: sess } = await supabase.from('sessions').select('status').eq('id', sid).single();
    onStatus?.(sess?.status);

    channels.lobby?.unsubscribe();
    channels.lobby = supabase.channel('lobby:' + sid)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'players', filter: `session_id=eq.${sid}` },
        async () => {
          const { data } = await supabase.from('players')
            .select('id,name,is_host,table_index,seat,connected')
            .eq('session_id', sid).order('created_at');
          onPlayers?.(data || []);
        })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'sessions', filter: `id=eq.${sid}` },
        (payload) => onStatus?.(payload.new.status))
      .subscribe();
    return channels.lobby;
  }

  // ---- 席割り確定→配り（主催） ----
  //   assignment: [[playerId, playerId, ...], ...]（各卓2〜8人）
  async function startRoom({ cards, assignment }) {
    const { data, error } = await supabase.rpc('start_session', {
      p_session: store.sessionId, p_host_token: store.hostToken,
      p_cards: cards, p_assignment: assignment,
    });
    if (error) throw error;
    return data; // { ok, phase:'trapping'|'playing' }
  }

  // ---- 罰ゲーム：罠を仕込む / 主催が締める ----
  async function setTrap({ card }) {
    const { data, error } = await supabase.rpc('set_trap', { p_session: store.sessionId, p_card: card });
    if (error) throw error;
    return data; // { ok, allSet }
  }
  async function beginPlay() {
    const { error } = await supabase.rpc('begin_play', { p_session: store.sessionId, p_host_token: store.hostToken });
    if (error) throw error;
  }

  // ---- 自分の卓/席を確定（開始後に呼ぶ） ----
  async function resolveMySeat() {
    const { data: me } = await supabase.from('players')
      .select('table_index,seat').eq('id', store.playerId).single();
    store.tableIndex = me?.table_index; store.seat = me?.seat;
    const { data: gt } = await supabase.from('game_tables')
      .select('id,version').eq('session_id', store.sessionId).eq('table_index', store.tableIndex).single();
    store.gameTableId = gt?.id; store.version = gt?.version ?? 0;
    return { tableIndex: store.tableIndex, seat: store.seat, gameTableId: store.gameTableId };
  }

  // ---- 自分の卓の状態を購読（場/手番/残り枚数/直近イベント） ----
  async function subscribeTable({ onTable, onEvent }) {
    if (!store.gameTableId) await resolveMySeat();
    const gtid = store.gameTableId;
    const { data: row } = await supabase.from('game_tables').select('*').eq('id', gtid).single();
    if (row) { store.version = row.version; onTable?.(row); }

    channels.table?.unsubscribe();
    channels.table = supabase.channel('table:' + gtid)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'game_tables', filter: `id=eq.${gtid}` },
        (payload) => {
          const row = payload.new;
          store.version = row.version;
          onTable?.(row);
          if (row.last_event) onEvent?.(row.last_event); // {type:'discard'|'penalty',...}
        })
      .subscribe();
    return channels.table;
  }

  // ---- 自分の手札を購読（本人だけに届く） ----
  async function subscribeHand({ onHand }) {
    const pid = store.playerId;
    const { data: h } = await supabase.from('player_hands').select('hand').eq('player_id', pid).maybeSingle();
    onHand?.(h?.hand || []);

    channels.hand?.unsubscribe();
    channels.hand = supabase.channel('hand:' + pid)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'player_hands', filter: `player_id=eq.${pid}` },
        (payload) => onHand?.(payload.new?.hand || []))
      .subscribe();
    return channels.hand;
  }

  // ---- 手を打つ（捨てて拾う）。stale なら最新versionで1回だけ自動リトライ ----
  //   move = { discard, drawKind:'pile'|'field', drawCard? }
  async function play(move) {
    const call = (ver) => supabase.rpc('play_move', {
      p_session: store.sessionId, p_table_index: store.tableIndex, p_version: ver,
      p_discard: move.discard, p_draw_kind: move.drawKind, p_draw_card: move.drawCard ?? null,
    });
    let { data, error } = await call(store.version);
    if (error && /stale/i.test(error.message)) {
      const { data: gt } = await supabase.from('game_tables').select('version').eq('id', store.gameTableId).single();
      store.version = gt?.version ?? store.version;
      ({ data, error } = await call(store.version));
    }
    if (error) throw error;
    if (typeof data?.version === 'number') store.version = data.version;
    return data; // { ok, drew, version, finalTurnsLeft, tableStatus, penalty }
  }

  // ---- 主催が途中終了（結果発表へ） ----
  async function finishRoom() {
    const { error } = await supabase.rpc('finish_session', { p_session: store.sessionId, p_host_token: store.hostToken });
    if (error) throw error;
  }

  // ---- 結果発表：卓の全員の最後の5枚を取得 ----
  async function fetchReveal() {
    const { data } = await supabase.from('players')
      .select('id,name,seat,final_hand')
      .eq('session_id', store.sessionId).eq('table_index', store.tableIndex).order('seat');
    return data || [];
  }

  // ---- 再接続：復帰時に卓と手札を取り直す（チャンネルは自動再接続） ----
  async function resync({ onTable, onHand } = {}) {
    if (store.gameTableId) {
      const { data: row } = await supabase.from('game_tables').select('*').eq('id', store.gameTableId).single();
      if (row) { store.version = row.version; onTable?.(row); }
    }
    if (store.playerId) {
      const { data: h } = await supabase.from('player_hands').select('hand').eq('player_id', store.playerId).maybeSingle();
      onHand?.(h?.hand || []);
    }
  }
  function bindReconnect(cbs) {
    const fn = () => { if (document.visibilityState === 'visible') resync(cbs); };
    document.addEventListener('visibilitychange', fn);
    window.addEventListener('online', fn);
    return () => { document.removeEventListener('visibilitychange', fn); window.removeEventListener('online', fn); };
  }

  function leave() { Object.values(channels).forEach((c) => c?.unsubscribe()); }

  return {
    supabase, store,
    ensureAuth, loadLocal,
    createRoom, joinRoom,
    subscribeLobby, startRoom, setTrap, beginPlay,
    resolveMySeat, subscribeTable, subscribeHand,
    play, finishRoom, fetchReveal,
    resync, bindReconnect, leave,
  };
}

/* ============================================================
   UI 配線の流れ（プレビュー画面との対応）
   ------------------------------------------------------------
   const net = createGameNet({ url: SUPABASE_URL, anonKey: SUPABASE_ANON_KEY });

   // s-deck/s-setup → 主催:
   await net.createRoom({ deckKey, penalty: penaltyMode, tableTarget: 6, name });
   // 参加者(QR遷移先): await net.joinRoom({ code, name });

   // s-lobby:
   await net.subscribeLobby({
     onPlayers: (ps) => renderLobby(ps),               // 名簿・人数を更新
     onStatus:  (st) => { if (st==='trapping') goTraps(); else if (st==='playing') goTable(); },
   });

   // s-assign（主催）→ start:
   await net.startRoom({ cards: DECKS[deckKey].cards, assignment }); // [[pid,...],...]

   // s-traps（罰ゲームON時・各自）:
   await net.setTrap({ card: chosen });    // 全員設定で onStatus が 'playing' に
   // 主催が締めるなら: await net.beginPlay();

   // s-table:
   await net.resolveMySeat();
   await net.subscribeHand({ onHand: (hand) => renderHand(hand) });
   await net.subscribeTable({
     onTable: (t) => renderTable(t),       // field/turn_seat/pile_count/final_turns_left/status
     onEvent: (e) => {                     // 読み上げ・罰ゲーム
       if (e.type === 'discard') showAnnounceDiscard(e.card);
       if (e.type === 'penalty') showPenalty(e.drawer, e.setter, e.card);
     },
   });
   net.bindReconnect({ onTable: renderTable, onHand: renderHand });

   // 自分の手番（turn_seat === net.store.seat）で:
   const res = await net.play({ discard, drawKind:'pile', drawCard:null });
   // 自分が引いた札は res.drew（自席の読み上げ表示に使う）。手札は subscribeHand で届く。

   // 終了/結果:
   // status が 'done' になったら（onTable / onStatus）:
   const rows = await net.fetchReveal();   // [{name, seat, final_hand}]
   renderReveal(rows);
   // 主催の途中終了: await net.finishRoom();
   ============================================================ */
