-- 개인정보 동의, 회원 탈퇴·팀 삭제, 운영자 통계
-- schema.sql(그리고 02_feedback.sql)을 이미 실행한 프로젝트에서 한 번 실행하세요.
-- Supabase > SQL Editor > New query 에 붙여넣고 Run

-- 동의 기록 ------------------------------------------------------------------
create table if not exists public.consents (
  user_id        uuid primary key references auth.users on delete cascade,
  version        text not null,
  under14        boolean not null default false,
  guardian_name  text,
  agreed_at      timestamptz not null default now()
);
alter table public.consents enable row level security;   -- 정책 없음: 아래 함수로만 접근

-- 운영자 목록 (여기에 등록된 계정만 통계를 볼 수 있어요) ---------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users on delete cascade
);
alter table public.admins enable row level security;     -- 정책 없음

revoke all on public.consents, public.admins from anon, authenticated;

-- 동의 저장 ------------------------------------------------------------------
create or replace function public.give_consent(p_version text, p_under14 boolean, p_guardian text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if p_under14 and coalesce(trim(p_guardian), '') = '' then raise exception '보호자 이름을 입력해 주세요'; end if;
  insert into public.consents (user_id, version, under14, guardian_name, agreed_at)
  values (auth.uid(), p_version, coalesce(p_under14, false), nullif(trim(p_guardian), ''), now())
  on conflict (user_id) do update
    set version = excluded.version, under14 = excluded.under14,
        guardian_name = excluded.guardian_name, agreed_at = now();
end $$;

-- 내 정보 (동의·운영자 여부 포함) -------------------------------------------------
create or replace function public.my_membership() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'role', m.role, 'name', m.name,
    'team', json_build_object('id', t.id, 'name', t.name, 'code', t.code,
            'coach_code', case when m.role = 'coach' then t.coach_code end),
    'consent', (select json_build_object('version', c.version, 'agreed_at', c.agreed_at, 'under14', c.under14)
                from public.consents c where c.user_id = auth.uid()),
    'is_admin', exists (select 1 from public.admins a where a.user_id = auth.uid()))
  from public.members m join public.teams t on t.id = m.team_id
  where m.user_id = auth.uid()
$$;

-- 회원 탈퇴: 내 계정과 내 데이터 삭제 ----------------------------------------------
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare m public.members; my_ath text[];
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  select * into m from public.members where user_id = auth.uid();
  if found then
    if m.role = 'coach'
       and not exists (select 1 from public.members where team_id = m.team_id and role = 'coach' and user_id <> auth.uid())
       and exists (select 1 from public.members where team_id = m.team_id and user_id <> auth.uid()) then
      raise exception '팀에 다른 코치가 없어요. 다른 코치를 먼저 초대하거나, 선수 관리 탭에서 팀을 삭제해 주세요';
    end if;
    select array_agg(id::text) into my_ath from public.docs
      where team_id = m.team_id and collection = 'athletes' and data->>'userId' = auth.uid()::text;
    -- 내 기록 (내가 쓴 것 + 코치가 나 대신 쓴 것), 내 피드백, 내 시트레이스, 내 선수 정보
    delete from public.docs where team_id = m.team_id and collection = 'records'
      and (created_by = auth.uid() or data->>'athleteId' = any(coalesce(my_ath, '{}')));
    delete from public.docs where team_id = m.team_id and collection = 'feedback'
      and (data->>'athleteUserId' = auth.uid()::text or data->>'athleteId' = any(coalesce(my_ath, '{}')));
    delete from public.docs where team_id = m.team_id and collection = 'seatraces' and created_by = auth.uid();
    delete from public.docs where team_id = m.team_id and collection = 'athletes' and data->>'userId' = auth.uid()::text;
    -- 코치가 남긴 피드백의 이름은 지움
    update public.docs set data = jsonb_set(data, '{fromName}', '"(탈퇴한 코치)"')
      where team_id = m.team_id and collection = 'feedback' and created_by = auth.uid();
    delete from public.members where user_id = auth.uid();
    if not exists (select 1 from public.members where team_id = m.team_id) then
      delete from public.teams where id = m.team_id;
    end if;
  end if;
  delete from auth.users where id = auth.uid();
end $$;

-- 팀 삭제 (코치만): 팀의 모든 기록·계획·피드백 삭제, 팀원은 팀에서 빠짐 ----------------
create or replace function public.delete_team() returns void
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  t := public.my_team();
  if t is null or not public.is_coach(t) then raise exception '코치만 팀을 삭제할 수 있어요'; end if;
  delete from public.teams where id = t;   -- docs, members 는 함께 삭제돼요
end $$;

-- 운영자 통계: 숫자만 (이름·기록 내용 없음) ----------------------------------------
create or replace function public.admin_stats() returns json
language plpgsql stable security definer set search_path = public as $$
declare result json;
begin
  if not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception '운영자만 볼 수 있어요';
  end if;
  select json_build_object(
    'teams', coalesce((select json_agg(x order by x.records_7d desc, x.created) from (
      select t.name, t.created_at::date as created,
        (select count(*) from public.members m where m.team_id = t.id and m.role = 'coach')   as coaches,
        (select count(*) from public.members m where m.team_id = t.id and m.role = 'athlete') as athletes,
        (select count(*) from public.docs d where d.team_id = t.id and d.collection = 'records') as records,
        (select count(*) from public.docs d where d.team_id = t.id and d.collection = 'records'
           and d.created_at > now() - interval '7 days') as records_7d,
        (select count(distinct d.created_by) from public.docs d where d.team_id = t.id and d.collection = 'records'
           and d.created_at > now() - interval '7 days') as active_7d,
        (select max(d.created_at)::date from public.docs d where d.team_id = t.id and d.collection = 'records') as last_record
      from public.teams t) x), '[]'::json),
    'users', (select count(*) from public.members),
    'under14', (select count(*) from public.consents where under14),
    'no_consent', (select count(*) from public.members m where not exists (select 1 from public.consents c where c.user_id = m.user_id)),
    'records_7d', (select count(*) from public.docs where collection = 'records' and created_at > now() - interval '7 days'),
    'active_7d', (select count(distinct created_by) from public.docs where collection = 'records' and created_at > now() - interval '7 days')
  ) into result;
  return result;
end $$;

grant execute on function public.give_consent(text, boolean, text) to authenticated;
grant execute on function public.delete_my_account() to authenticated;
grant execute on function public.delete_team() to authenticated;
grant execute on function public.admin_stats() to authenticated;
grant execute on function public.my_membership() to authenticated;

notify pgrst, 'reload schema';

-- 운영자 등록 방법 (본인 아이디로 바꿔서 따로 한 번 실행)
-- insert into public.admins (user_id)
--   select id from auth.users where email = '내아이디@rowingnote.app'
-- on conflict do nothing;
