-- 혼자 쓰기 (로잉머신 개인 사용자) 모드
-- 앞의 SQL(update_all.sql 또는 schema/02/03)을 실행한 프로젝트에서 한 번 실행하세요.

-- 팀 종류: team(조정팀) / solo(개인)
alter table public.teams add column if not exists kind text not null default 'team';
alter table public.teams drop constraint if exists teams_kind_check;
alter table public.teams add constraint teams_kind_check check (kind in ('team', 'solo'));

-- 개인 시작: 나 혼자만 있는 '팀'을 만들고 나를 선수로도 등록
create or replace function public.create_solo(p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare t public.teams;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '이미 팀에 속해 있어요'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception '이름을 입력해 주세요'; end if;
  insert into public.teams (name, code, coach_code, kind)
    values (trim(p_name) || '의 로잉', public.new_code(), public.new_code(), 'solo') returning * into t;
  insert into public.members (user_id, team_id, role, name) values (auth.uid(), t.id, 'coach', trim(p_name));
  insert into public.docs (team_id, collection, data, created_by)
    values (t.id, 'athletes', jsonb_build_object('name', trim(p_name), 'userId', auth.uid()::text,
            'createdAt', (extract(epoch from now()) * 1000)::bigint), auth.uid());
  return public.my_membership();
end $$;

-- 개인 공간에는 다른 사람이 코드로 들어올 수 없게
create or replace function public.join_team(p_code text, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare t public.teams; r text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if exists (select 1 from public.members where user_id = auth.uid()) then raise exception '이미 팀에 속해 있어요'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception '이름을 입력해 주세요'; end if;
  select * into t from public.teams where code = upper(trim(p_code)) and kind = 'team';
  if found then r := 'athlete';
  else
    select * into t from public.teams where coach_code = upper(trim(p_code)) and kind = 'team';
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

-- 내 정보에 팀 종류 추가
create or replace function public.my_membership() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'role', m.role, 'name', m.name,
    'team', json_build_object('id', t.id, 'name', t.name, 'kind', t.kind, 'code', t.code,
            'coach_code', case when m.role = 'coach' then t.coach_code end),
    'consent', (select json_build_object('version', c.version, 'agreed_at', c.agreed_at, 'under14', c.under14)
                from public.consents c where c.user_id = auth.uid()),
    'is_admin', exists (select 1 from public.admins a where a.user_id = auth.uid()))
  from public.members m join public.teams t on t.id = m.team_id
  where m.user_id = auth.uid()
$$;

-- 운영자 통계에 개인/팀 구분 추가
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
      from public.teams t where t.kind = 'team') x), '[]'::json),
    'users', (select count(*) from public.members),
    'solo_users', (select count(*) from public.teams where kind = 'solo'),
    'solo_active_7d', (select count(distinct d.created_by) from public.docs d join public.teams t on t.id = d.team_id
                        where t.kind = 'solo' and d.collection = 'records' and d.created_at > now() - interval '7 days'),
    'under14', (select count(*) from public.consents where under14),
    'no_consent', (select count(*) from public.members m where not exists (select 1 from public.consents c where c.user_id = m.user_id)),
    'records_7d', (select count(*) from public.docs where collection = 'records' and created_at > now() - interval '7 days'),
    'active_7d', (select count(distinct created_by) from public.docs where collection = 'records' and created_at > now() - interval '7 days')
  ) into result;
  return result;
end $$;

grant execute on function public.create_solo(text) to authenticated;
grant execute on function public.join_team(text, text) to authenticated;
grant execute on function public.my_membership() to authenticated;
grant execute on function public.admin_stats() to authenticated;

notify pgrst, 'reload schema';
