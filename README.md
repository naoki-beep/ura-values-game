# 裏価値観ゲーム

価値観カードゲーム（パロディ）の各自スマホ対応版。フロントは静的Web、バックエンドはSupabase（Postgres + RLS + Realtime + RPC）。

## 構成

```
web/index.html            フロント（現状はUX確定版プレビュー。ここに client-net を配線していく）
src/client-net.js         Supabase接続クライアント（匿名認証 / RPC / Realtime購読）
supabase/
  config.toml             Supabase CLI 設定
  migrations/
    0001_schema.sql        テーブル / RLS / Realtime（手札・山札・罠を分離して秘匿）
    0002_play.sql          play_move（手番処理＋終了ルール）/ finish_session
    0003_start.sql         create/join/start（配り）/ set_trap / begin_play
.github/workflows/deploy.yml  push時にDBマイグレーションを自動適用
```

## はじめに（一度だけ）

1. Supabaseでプロジェクト作成。
2. Dashboard > Authentication > Sign In/Providers で **Anonymous sign-ins を ON**。
3. ローカルにCLI: `npm i -g supabase`（または `brew install supabase/tap/supabase`）。
4. リポジトリ直下で:
   ```bash
   supabase login
   supabase link --project-ref <PROJECT_REF>
   supabase db push          # 0001→0003 が適用される
   ```
5. フロントは Vercel（または Cloudflare Pages / Netlify）にこのリポジトリを連携し、
   **Root Directory を `web` に**設定。ビルド不要の静的配信。

## Git修正で随時反映（これがやりたいこと）

**データベース（スキーマ・関数）**
- 変更は「既存ファイルを編集」ではなく **`supabase/migrations/` に新しい番号のSQLを追加**する。
  例: 関数を直したいなら `0004_play_v2.sql` を作り、`create or replace function play_move(...)` を丸ごと入れる。
  （関数は `CREATE OR REPLACE` なので新マイグレーションで上書きできる。テーブルは `ALTER TABLE ...` を追記）
- `main` に push すると `.github/workflows/deploy.yml` が走り、`supabase db push` で**未適用分だけ**反映。
- ⚠️ 一度適用したマイグレーションは編集しない（再実行されない）。必ず新ファイルを足す。

**フロント**
- Vercel等にリポジトリを連携しておけば、`web/` への変更を push するたびに**自動で再デプロイ**。

つまり日々の運用は「直す → 新マイグレーション or web を編集 → `git push`」だけ。

## 必要な GitHub Secrets（Settings > Secrets and variables > Actions）

| Secret | 取得元 |
|---|---|
| `SUPABASE_ACCESS_TOKEN` | Supabase Account > Access Tokens |
| `SUPABASE_PROJECT_REF`  | プロジェクト設定の Reference ID |
| `SUPABASE_DB_PASSWORD`  | プロジェクト作成時のDBパスワード |

## ローカルで手動反映したいとき

```bash
supabase db push     # マイグレーションを本番へ
# 新規作成例:
supabase migration new add_xxx   # 空のSQLができるので中身を書いて push
```

## 状態（2026-06 時点）
- バックエンドのゲーム進行（作成/参加/配り/手番/終了/罰ゲーム）は実装済み。
- フロントは見た目・操作の確定版。次は `web/index.html` のデモ関数を `src/client-net.js` の呼び出しへ差し替える配線作業。
