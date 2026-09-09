-- Supabase Security Advisor 修复：
--   1) ERROR  rls_disabled_in_public      -> public.cli_login_sessions
--   2) WARN   function_search_path_mutable -> public 下所有 SECURITY DEFINER 函数
--
-- 幂等：可重复执行，也可直接粘贴进 Supabase SQL Editor 运行。

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) public.cli_login_sessions 从未启用 RLS
--
-- 20260331_create_cli_login_sessions.sql 只建了表和两个索引，没有 enable row
-- level security、没有任何 policy、也没有 revoke。而这张表存的是
-- encrypted_access_token / encrypted_refresh_token / auth_code_hash /
-- auth_user_id —— 在 public schema 里，PostgREST 默认就把它暴露给 anon 和
-- authenticated 角色。这是 Advisor 里的 ERROR 级别项。
--
-- 全仓检索（Swift / Edge Functions / Scripts / Android 六个模块）对
-- cli_login_sessions 的引用数为 0：没有任何客户端代码读写它。因此在表权限和
-- RLS 两个边界同时拒掉所有客户端角色不会破坏任何现有流程。
-- service_role 绕过 RLS，将来真要接 CLI 登录时从服务端走即可。
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.cli_login_sessions enable row level security;

revoke all privileges on table public.cli_login_sessions
    from public, anon, authenticated;

grant select, insert, update, delete
    on table public.cli_login_sessions
    to service_role;

-- 刻意不建任何 policy：service_role 绕过 RLS，其余角色应当一行都读不到。

-- ─────────────────────────────────────────────────────────────────────────────
-- 2) SECURITY DEFINER 函数的 search_path 未固定
--
-- 001_registration_security.sql 和 002_verification_code_service.sql 共 15 个
-- SECURITY DEFINER 函数，创建时都没有 SET search_path（这两个文件里
-- "set search_path" 出现次数为 0）。20260802000000_harden_auth_privilege_
-- boundaries.sql 已经把 EXECUTE 从 anon/authenticated 收回（很好的缓解），
-- 但它只改授权、没有改函数定义，所以 Advisor 仍然会持续报这 15 条。
--
-- 用 ALTER FUNCTION ... SET search_path 而不是重建函数体：不改行为，只固定
-- 名字解析，避免重写 15 个函数带来的回归风险。
--
-- 用 pg_proc 循环而不是逐个写签名：001/002 里的函数在后续迁移中被多次
-- 重定义过（20260412 / 20260415 / 20260424 / 20260802），手写签名容易和线上
-- 实际签名对不上导致 ALTER 报错。这里按 oid::regprocedure 取真实签名。
--
-- 顺序说明：pg_temp 必须放最后。放前面等于允许调用方用临时表/临时函数
-- 劫持解析，那正是这条 lint 想防的攻击。extensions 要带上，因为
-- 20260405134000_avatar_b2_nebula_frozen.sql 之后的代码走 extensions.digest。
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare
    target record;
    pinned integer := 0;
begin
    for target in
        select p.oid::regprocedure as signature
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.prosecdef                       -- 仅 SECURITY DEFINER
          and not exists (
              select 1
              from unnest(coalesce(p.proconfig, '{}'::text[])) as cfg
              where cfg like 'search\_path=%'
          )
        order by 1
    loop
        execute format(
            'alter function %s set search_path = public, extensions, pg_temp',
            target.signature
        );
        pinned := pinned + 1;
        raise notice 'search_path pinned: %', target.signature;
    end loop;

    raise notice 'total SECURITY DEFINER functions pinned: %', pinned;
end $$;

commit;

-- ─────────────────────────────────────────────────────────────────────────────
-- 本脚本覆盖不到、只能在 Dashboard 里改的 Advisor 项（如果你的告警列表里有）：
--   * auth_leaked_password_protection —— Authentication > Policies，
--     打开 "Leaked password protection"（对接 HaveIBeenPwned）。
--   * insufficient_mfa_options —— Authentication > Providers，至少启用一种 MFA。
--   * extension_in_public —— 20260405134000_avatar_b2_nebula_frozen.sql:3 的
--     `create extension if not exists pgcrypto;` 没写 schema。如果该扩展当初
--     确实落在了 public，需要 `alter extension pgcrypto set schema extensions;`。
--     但仓库里其余代码调用的是 extensions.digest(...)，说明线上很可能已经在
--     extensions 里、这句是空操作 —— 执行前请先在 Dashboard 确认，不要盲改。
-- ─────────────────────────────────────────────────────────────────────────────
