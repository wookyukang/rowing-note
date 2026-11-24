-- 코치 피드백 기능 추가 (schema.sql 을 이미 실행한 프로젝트에서 한 번 실행하세요)
-- Supabase > SQL Editor > New query 에 붙여넣고 Run

-- 1) 'feedback' 종류의 데이터 허용
alter table public.docs drop constraint if exists docs_collection_check;
alter table public.docs add constraint docs_collection_check
  check (collection in ('athletes', 'records', 'plans', 'seatraces', 'feedback'));

-- 2) 피드백은 코치와 해당 선수만 볼 수 있게
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select using (
  team_id = public.my_team() and (
    collection <> 'feedback'
    or public.is_coach(team_id)
    or data->>'athleteUserId' = auth.uid()::text
  )
);

-- 3) 선수는 자기 피드백에 '확인'과 '답장'만 할 수 있게
drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update using (
  team_id = public.my_team() and (
    public.is_coach(team_id)
    or (collection in ('records', 'seatraces') and created_by = auth.uid())
    or (collection = 'athletes' and data->>'userId' = auth.uid()::text)
    or (collection = 'feedback' and data->>'athleteUserId' = auth.uid()::text)
  )
) with check (team_id = public.my_team());

notify pgrst, 'reload schema';
