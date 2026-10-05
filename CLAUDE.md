# PharmaLex v2

Extend PharmaLex (Malaysian pharmacy law study app) into a full-stack app.
We rebuild the code fresh. We keep the content and gameplay ideas, not the old code.

Source content: /docs/pharmalex-legacy.html
(single HTML file, all data inline in the script block, no separate data.js)

## Product
- Student front end: Play (gamified), Learn (notes, flashcards, law text), Test (timed mock exams)
- Lecturer back end: manage questions, notes, exams; view class analytics
- Mobile-first, responsive for phone, tablet, desktop; installable PWA

## Stack
Next.js (App Router, TypeScript) on Vercel; Supabase (Postgres + Auth + RLS); Tailwind.
No other services without asking me.

## Roles
student, lecturer, admin. Enforce with Supabase row-level security, not just UI checks.

## Content rules (critical)
- Every question has: act, section, source citation, verified_by, verified_at, status
- status values: draft / needs_review / verified. ALL imported questions start as needs_review.
- Never invent statute sections. If unsure, mark needs_review.
- Never mark anything verified. Only the lecturers do that.
- Content is as of June 2026. Always verify against latest gazetted versions.

## Authorship and licence
Co-developed by Dr. Shamin Mohd Saffian (UKM) and Assoc. Prof. Dr. Amirah Mohd Gazzali (USM).
Free for educational use. Not for commercial distribution. Not legal advice.
Keep this notice in the app footer.

## Assumptions (change if I say so)
Multi-school (UKM + USM) with nullable school_id, English only,
email + Google login, nickname leaderboard (PDPA-conscious).

## Working rules
- Build ONE piece at a time, then STOP and summarise what you did. Wait for my go-ahead.
- No over-verification loops on simple tasks.
- Never commit secrets. Use .env.local and .env.example.
- Never apply migrations to a live Supabase project without my approval.
- If only one file changed, show me that file's content.

## Build order
1 DB schema + RLS | 2 Question import from legacy | 3 Skeleton + auth
4 Learn + Quiz | 5 Timed mock exam | 6 Analytics + leaderboard | 7 Lecturer dashboard
