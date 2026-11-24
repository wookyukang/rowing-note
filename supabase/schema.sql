-- 로잉노트 데이터베이스 설정
-- Supabase 대시보드 > SQL Editor > New query 에 이 파일 내용을 전부 붙여넣고 Run 하세요.
-- 여러 번 실행해도 안전하게 만들어져 있어요.

create extension if not exists pgcrypto;

-- 팀 -----------------------------------------------------------------------
create table if not exists public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  code        text not null unique,   -- 선수 가입 코드
  coach_code  text not null unique,   -- 코치 가입 코드
  created_at  timestamptz not null default now()
);

-- 팀원 (계정 1개 = 팀 1개) ---------------------------------------------------
create table if not exists public.members (
  user_id     uuid primary key references auth.users on delete cascade,
  team_id     uuid not null references public.teams on delete cascade,
  role        text not null check (role in ('coach', 'athlete')),
  name        text not null,
  created_at  timestamptz not null default now()
);

-- 기록·계획·선수 등 모든 데이터 (collection 으로 구분) -------------------------
create table if not exists public.docs (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams on delete cascade,
  collection  text not null check (collection in ('athletes', 'records', 'plans', 'seatraces')),
  data        jsonb not null default '{}'::jsonb,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists docs_team_collection on public.docs (team_id, collection);

alter table public.teams   enable row level security;
alter table public.members enable row level security;
alter table public.docs    enable row level security;

-- 도우미 함수 ----------------------------------------------------------------
create or replace function public.my_team() returns uuid
language sql stable security definer set search_path = public as $$
  select team_id from public.members where user_id = auth.uid()
$$;

create or replace function public.is_coach(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where user_id = auth.uid() and team_id = t and role = 'coach')
$$;

-- 권한 규칙 ------------------------------------------------------------------
-- teams 는 직접 읽지 않고 my_membership() 함수로만 읽어요 (선수에게 코치 코드가 보이지 않게).
drop policy if exists members_select on public.members;
create policy members_select on public.members for select using (team_id = public.my_team());

drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select using (team_id = public.my_team());

-- 기록·시트레이스는 팀원 누구나, 선수 명단·훈련 계획은 코치만 추가
drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert with check (
  team_id = public.my_team()
  and created_by = auth.uid()
  and (collection in ('records', 'seatraces') or public.is_coach(team_id))
);

-- 수정: 코치는 전부, 선수는 자기가 쓴 기록과 자기 선수 정보만
drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update using (
  team_id = public.my_team() and (
    public.is_coach(team_id)
    or (collection in ('records', 'seatraces') and created_by = auth.uid())
    or (collection = 'athletes' and data->>'userId' = auth.uid()::text)
  )
) with check (team_id = public.my_team());

-- 삭제: 코치는 전부, 선수는 자기가 쓴 기록만
drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete using (
  team_id = public.my_team() and (
    public.is_coach(team_id)
    or (collection in ('records', 'seatraces') and created_by = auth.uid())
  )
);

-- 팀 만들기 / 가입 / 내 정보 ---------------------------------------------------
create or replace function public.new_code() returns text
language sql volatile as $$
  select upper(substr(md5(gen_random_uuid()::text), 1, 6))
$$;

create or replace function public.create_team(p_team text, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare t public.teams;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '이미 팀에 속해 있어요'; end if;
  if coalesce(trim(p_team), '') = '' or coalesce(trim(p_name), '') = '' then raise exception '팀 이름과 내 이름을 입력해 주세요'; end if;
  insert into public.teams (name, code, coach_code) values (trim(p_team), public.new_code(), public.new_code()) returning * into t;
  insert into public.members (user_id, team_id, role, name) values (auth.uid(), t.id, 'coach', trim(p_name));
  return public.my_membership();
end $$;

create or replace function public.join_team(p_code text, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare t public.teams; r text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '이미 팀에 속해 있어요'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception '이름을 입력해 주세요'; end if;
  select * into t from public.teams where code = upper(trim(p_code));
  if found then r := 'athlete';
  else
    select * into t from public.teams where coach_code = upper(trim(p_code));
    if found then r := 'coach'; else raise exception '팀 코드를 찾을 수 없어요'; end if;
  end if;
  insert into public.members (user_id, team_id, role, name) values (auth.uid(), t.id, r, trim(p_name));
  if r = 'athlete' then
    insert into public.docs (team_id, collection, data, created_by)
    values (t.id, 'athletes', jsonb_build_object('name', trim(p_name), 'userId', auth.uid()::text,
            'createdAt', (extract(epoch from now()) * 1000)::bigint), auth.uid());
  end if;
  return public.my_membership();
end $$;

create or replace function public.my_membership() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'role', m.role, 'name', m.name,
    'team', json_build_object('id', t.id, 'name', t.name, 'code', t.code,
            'coach_code', case when m.role = 'coach' then t.coach_code end))
  from public.members m join public.teams t on t.id = m.team_id
  where m.user_id = auth.uid()
$$;

-- 테이블 사용 권한 (새 Supabase 프로젝트는 자동으로 주지 않는 경우가 있어요)
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.docs to authenticated;
grant select on public.members to authenticated;
revoke all on public.teams from anon, authenticated;
revoke all on public.docs, public.members from anon;

grant execute on function public.create_team(text, text) to authenticated;
grant execute on function public.join_team(text, text) to authenticated;
grant execute on function public.my_membership() to authenticated;

-- 실시간 업데이트 (다른 사람이 기록하면 바로 보이게) ------------------------------
alter table public.docs replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- 설정 변경을 API에 바로 반영
notify pgrst, 'reload schema';
