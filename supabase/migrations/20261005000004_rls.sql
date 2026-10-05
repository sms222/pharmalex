-- PharmaLex v2 · migration 4/4 · row-level security + grants
-- Roles: student < lecturer < admin. Helper functions are in migration 1 (private.*).
-- "visible school" = row.school_id is null (shared bank) OR equals the caller's school OR caller is admin.

alter table public.schools        enable row level security;
alter table public.profiles       enable row level security;
alter table public.acts           enable row level security;
alter table public.questions      enable row level security;
alter table public.lesson_notes   enable row level security;
alter table public.flashcards     enable row level security;
alter table public.law_texts      enable row level security;
alter table public.user_stats     enable row level security;
alter table public.attempts       enable row level security;
alter table public.exams          enable row level security;
alter table public.exam_questions enable row level security;
alter table public.exam_attempts  enable row level security;
alter table public.error_reports  enable row level security;

-- ── schools ──
create policy schools_read  on public.schools for select to anon, authenticated using (true);                      -- signup school picker
create policy schools_admin on public.schools for all    to authenticated using (private.is_admin()) with check (private.is_admin());  -- only admins edit schools

-- ── acts ──
create policy acts_read  on public.acts for select to anon, authenticated using (true);                            -- Act list is public reference data
create policy acts_admin on public.acts for all    to authenticated using (private.is_admin()) with check (private.is_admin());

-- ── profiles ──
create policy profiles_self_read   on public.profiles for select to authenticated using (id = (select auth.uid()));          -- see your own profile
create policy profiles_staff_read  on public.profiles for select to authenticated using (private.same_school(id));           -- lecturers see their school's students; admins see all
create policy profiles_self_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));                                                    -- edit own nickname/opt-in/school (role+school locked by trigger)
create policy profiles_admin_update on public.profiles for update to authenticated
  using (private.is_admin()) with check (private.is_admin());                                                                -- admins manage users and roles
create policy profiles_admin_delete on public.profiles for delete to authenticated using (private.is_admin());               -- admins can remove users

-- ── content tables: questions, lesson_notes, flashcards, law_texts ──
-- Students: verified rows in a visible school. Staff: any status in a visible school.
do $$
declare t text;
begin
  foreach t in array array['questions', 'lesson_notes', 'flashcards', 'law_texts'] loop
    execute format($f$create policy %1$s_read on public.%1$s for select to authenticated
      using (private.school_visible(school_id) and (status = 'verified' or private.is_staff()))$f$, t);            -- students read verified only; staff read everything in scope
    execute format($f$create policy %1$s_staff_insert on public.%1$s for insert to authenticated
      with check (private.is_staff() and private.school_visible(school_id))$f$, t);                                -- lecturers add content (guard trigger blocks self-marking as verified by non-staff/imports)
    execute format($f$create policy %1$s_staff_update on public.%1$s for update to authenticated
      using (private.is_staff() and private.school_visible(school_id))
      with check (private.is_staff() and private.school_visible(school_id))$f$, t);                                -- lecturers edit/verify content; editing verified content resets it to needs_review
    execute format($f$create policy %1$s_staff_delete on public.%1$s for delete to authenticated
      using (private.is_staff() and private.school_visible(school_id) and (status <> 'verified' or private.is_admin()))$f$, t);  -- verified content can only be deleted by an admin
  end loop;
end $$;

-- ── user_stats ──
create policy stats_self_read on public.user_stats for select to authenticated using (user_id = (select auth.uid()));  -- see your own XP/hearts; writes happen only via triggers

-- ── attempts ──
create policy attempts_self_read    on public.attempts for select to authenticated using (user_id = (select auth.uid()));  -- students see their own history
create policy attempts_staff_read   on public.attempts for select to authenticated using (private.same_school(user_id));    -- lecturers see their school's attempts (class analytics)
create policy attempts_self_insert  on public.attempts for insert to authenticated with check (user_id = (select auth.uid())); -- write only your own; no update/delete → history is append-only

-- ── exams ──
create policy exams_read on public.exams for select to authenticated
  using (private.school_visible(school_id) and (is_published or private.is_staff()));                                   -- students see published exams; staff see drafts too
create policy exams_staff_write on public.exams for all to authenticated
  using (private.is_staff() and private.school_visible(school_id))
  with check (private.is_staff() and private.school_visible(school_id));                                                -- lecturers manage exams in their scope

create policy exam_questions_read on public.exam_questions for select to authenticated
  using (exists (select 1 from public.exams e where e.id = exam_id));                                                   -- inherits exam visibility (exams RLS applies inside the subquery)
create policy exam_questions_staff_write on public.exam_questions for all to authenticated
  using (private.is_staff() and exists (select 1 from public.exams e where e.id = exam_id))
  with check (private.is_staff() and exists (select 1 from public.exams e where e.id = exam_id));                       -- lecturers edit the question list of exams they can see

-- ── exam_attempts ── (no insert/update policy: only start_exam_attempt / submit_exam_attempt RPCs write)
create policy exam_attempts_self_read  on public.exam_attempts for select to authenticated using (user_id = (select auth.uid())); -- students see own attempts
create policy exam_attempts_staff_read on public.exam_attempts for select to authenticated using (private.same_school(user_id));   -- lecturers see their school's exam results

-- ── error_reports ──
create policy reports_self_insert on public.error_reports for insert to authenticated
  with check (reporter_id = (select auth.uid()) and status = 'open' and resolved_by is null);                           -- students file reports as themselves, always 'open'
create policy reports_self_read   on public.error_reports for select to authenticated using (reporter_id = (select auth.uid()));  -- students track their own reports
create policy reports_staff_read  on public.error_reports for select to authenticated using (private.is_staff());       -- lecturers triage all reports
create policy reports_staff_update on public.error_reports for update to authenticated
  using (private.is_staff()) with check (private.is_staff());                                                           -- lecturers resolve/reject reports
create policy reports_admin_delete on public.error_reports for delete to authenticated using (private.is_admin());      -- only admins delete reports

-- ── function exposure: RPCs callable by signed-in users only ──
revoke execute on function public.start_exam_attempt(uuid, text, integer)  from public, anon;
revoke execute on function public.submit_exam_attempt(uuid, jsonb)         from public, anon;
revoke execute on function public.get_leaderboard(uuid, integer)           from public, anon;
revoke execute on function public.class_question_stats(text)               from public, anon;
grant  execute on function public.start_exam_attempt(uuid, text, integer)  to authenticated;
grant  execute on function public.submit_exam_attempt(uuid, jsonb)         to authenticated;
grant  execute on function public.get_leaderboard(uuid, integer)           to authenticated;
grant  execute on function public.class_question_stats(text)               to authenticated;   -- function itself re-checks is_staff()

-- RLS helper functions must be executable by the roles whose policies call them.
grant execute on all functions in schema private to authenticated, anon;
