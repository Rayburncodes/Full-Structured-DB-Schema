-- ============================================================
-- KINETIC — Supabase Schema
-- Run this in the Supabase SQL Editor (top → bottom order)
-- ============================================================

-- ── 1. USER PROFILES ────────────────────────────────────────
-- Extends Supabase's built-in auth.users.
-- We do NOT recreate a users table — auth.users IS the users table.

CREATE TABLE public.user_profiles (
  profile_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name        TEXT,
  date_of_birth       DATE,
  fitness_goals       TEXT[],                   -- e.g. ARRAY['strength','weight_loss']
  injury_history      JSONB DEFAULT '[]'::JSONB, -- [{region, severity, notes}]
  training_frequency  SMALLINT CHECK (training_frequency BETWEEN 1 AND 7),
  experience_level    TEXT CHECK (experience_level IN ('beginner','intermediate','advanced')),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_user_profiles_user_id ON public.user_profiles(user_id);

-- Auto-create a profile row whenever a new auth user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.user_profiles (user_id)
  VALUES (NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── 2. EXERCISES ─────────────────────────────────────────────

CREATE TABLE public.exercises (
  exercise_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL UNIQUE,
  type            TEXT NOT NULL CHECK (type IN ('strength','cardio','mobility','plyometric')),
  muscle_groups   TEXT[],                        -- e.g. ARRAY['quads','glutes']
  equipment       TEXT[],
  difficulty      TEXT CHECK (difficulty IN ('beginner','intermediate','advanced')),
  description     TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_exercises_type ON public.exercises(type);
CREATE INDEX idx_exercises_name ON public.exercises(name);

-- Seed some starter exercises
INSERT INTO public.exercises (name, type, muscle_groups, equipment, difficulty) VALUES
  ('Back Squat',       'strength',  ARRAY['quads','glutes','hamstrings'], ARRAY['barbell','rack'], 'intermediate'),
  ('Deadlift',         'strength',  ARRAY['hamstrings','glutes','back'],  ARRAY['barbell'],        'intermediate'),
  ('Bench Press',      'strength',  ARRAY['chest','triceps','shoulders'], ARRAY['barbell','bench'],'intermediate'),
  ('Pull-Up',          'strength',  ARRAY['lats','biceps'],               ARRAY['pull-up bar'],    'intermediate'),
  ('Overhead Press',   'strength',  ARRAY['shoulders','triceps'],         ARRAY['barbell'],        'intermediate'),
  ('Romanian Deadlift','strength',  ARRAY['hamstrings','glutes'],         ARRAY['barbell'],        'beginner'),
  ('Goblet Squat',     'strength',  ARRAY['quads','glutes'],              ARRAY['kettlebell'],     'beginner'),
  ('Hip Thrust',       'strength',  ARRAY['glutes'],                      ARRAY['barbell','bench'],'beginner');

-- ── 3. FORM ANALYSES ─────────────────────────────────────────

CREATE TABLE public.form_analyses (
  session_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  exercise_id       UUID NOT NULL REFERENCES public.exercises(exercise_id),
  weight_kg         NUMERIC(6,2),               -- nullable: bodyweight moves
  reps              SMALLINT,
  sets              SMALLINT,
  video_url         TEXT NOT NULL,               -- Supabase Storage object path
  video_duration_s  SMALLINT,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','processing','completed','failed')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_form_analyses_user_id        ON public.form_analyses(user_id);
CREATE INDEX idx_form_analyses_exercise_id    ON public.form_analyses(exercise_id);
CREATE INDEX idx_form_analyses_status         ON public.form_analyses(status);
CREATE INDEX idx_form_analyses_user_created   ON public.form_analyses(user_id, created_at DESC);

-- ── 4. FORM ANALYSIS RESULTS ──────────────────────────────────

CREATE TABLE public.form_analysis_results (
  result_id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id                  UUID NOT NULL UNIQUE REFERENCES public.form_analyses(session_id) ON DELETE CASCADE,
  overall_score               NUMERIC(4,1) NOT NULL CHECK (overall_score BETWEEN 0 AND 100),
  depth_score                 NUMERIC(4,1) CHECK (depth_score BETWEEN 0 AND 100),
  alignment_score             NUMERIC(4,1) CHECK (alignment_score BETWEEN 0 AND 100),
  tempo_score                 NUMERIC(4,1) CHECK (tempo_score BETWEEN 0 AND 100),
  issues                      JSONB DEFAULT '[]'::JSONB,
    -- [{frame_ts, severity: 'critical'|'warning'|'info', description, cue}]
  coaching_output             JSONB DEFAULT '{}'::JSONB,
    -- {summary, cues: [], drills: [], priority_fixes: []}
  progression_recommendation  TEXT NOT NULL
                                CHECK (progression_recommendation IN ('deload','maintain','progress','regress')),
  annotated_frame_urls        TEXT[],           -- Supabase Storage object paths
  model_version               TEXT NOT NULL,    -- e.g. 'kinetic-v1.2'
  created_at                  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_form_analysis_session_id ON public.form_analysis_results(session_id);

-- ── 5. WORKOUT PLAN EXERCISES ─────────────────────────────────

CREATE TABLE public.workout_plan_exercises (
  plan_exercise_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  exercise_id       UUID NOT NULL REFERENCES public.exercises(exercise_id),
  plan_name         TEXT NOT NULL,
  day_of_week       SMALLINT CHECK (day_of_week BETWEEN 1 AND 7),
  planned_sets      SMALLINT,
  planned_reps      SMALLINT,
  planned_weight_kg NUMERIC(6,2),
  notes             TEXT,
  sort_order        SMALLINT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_plan_exercises_user_id     ON public.workout_plan_exercises(user_id);
CREATE INDEX idx_plan_exercises_exercise_id ON public.workout_plan_exercises(exercise_id);

-- ── 6. WORKOUT SESSION LOGS ───────────────────────────────────

CREATE TABLE public.workout_session_logs (
  log_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  exercise_id       UUID NOT NULL REFERENCES public.exercises(exercise_id),
  plan_exercise_id  UUID REFERENCES public.workout_plan_exercises(plan_exercise_id),
  form_session_id   UUID REFERENCES public.form_analyses(session_id),
  logged_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  actual_sets       SMALLINT,
  actual_reps       SMALLINT,
  actual_weight_kg  NUMERIC(6,2),
  rpe               NUMERIC(3,1) CHECK (rpe BETWEEN 1 AND 10),  -- Rate of Perceived Exertion
  notes             TEXT
);

CREATE INDEX idx_session_logs_user_id         ON public.workout_session_logs(user_id);
CREATE INDEX idx_session_logs_exercise_id     ON public.workout_session_logs(exercise_id);
CREATE INDEX idx_session_logs_user_logged     ON public.workout_session_logs(user_id, logged_at DESC);
CREATE INDEX idx_session_logs_form_session_id ON public.workout_session_logs(form_session_id);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE public.user_profiles          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exercises              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.form_analyses          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.form_analysis_results  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_plan_exercises ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workout_session_logs   ENABLE ROW LEVEL SECURITY;

-- user_profiles: users can only read/write their own profile
CREATE POLICY "Users can view own profile"
  ON public.user_profiles FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update own profile"
  ON public.user_profiles FOR UPDATE TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- exercises: public read, no user writes (admin-managed via service role)
CREATE POLICY "Exercises are publicly readable"
  ON public.exercises FOR SELECT TO authenticated
  USING (is_active = TRUE);

-- form_analyses: users can only see/insert their own
CREATE POLICY "Users can view own form analyses"
  ON public.form_analyses FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own form analyses"
  ON public.form_analyses FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- form_analysis_results: readable if you own the linked session
CREATE POLICY "Users can view own analysis results"
  ON public.form_analysis_results FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.form_analyses fa
      WHERE fa.session_id = form_analysis_results.session_id
        AND fa.user_id = auth.uid()
    )
  );

-- workout_plan_exercises
CREATE POLICY "Users can manage own plan exercises"
  ON public.workout_plan_exercises FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- workout_session_logs
CREATE POLICY "Users can manage own session logs"
  ON public.workout_session_logs FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- SUPABASE STORAGE BUCKET (run via dashboard or here)
-- ============================================================

-- Create a private bucket for form videos and annotated frames
-- (videos are never public — always served via signed URLs)
INSERT INTO storage.buckets (id, name, public)
VALUES ('form-videos', 'form-videos', FALSE)
ON CONFLICT DO NOTHING;

-- Storage RLS: users can upload to their own folder only
CREATE POLICY "Users can upload own videos"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'form-videos' AND
    (storage.foldername(name))[1] = auth.uid()::TEXT
  );

CREATE POLICY "Users can view own videos"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'form-videos' AND
    (storage.foldername(name))[1] = auth.uid()::TEXT
  );
