-- ============================================================
-- ScaleLogix Pricing Calculator — Full Supabase Migration
-- Run this file in the Supabase SQL Editor as a single script.
-- ============================================================

-- ##########################################################
-- 1. TABLES (created first so functions can reference them)
-- ##########################################################

-- 2a. profiles
CREATE TABLE public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       TEXT NOT NULL,
  full_name   TEXT,
  role        TEXT NOT NULL CHECK (role IN ('sales', 'client')) DEFAULT 'client',
  org_name    TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2b. pricing_config (append-only audit trail)
CREATE TABLE public.pricing_config (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dev_rate                NUMERIC(8,2)  NOT NULL DEFAULT 105.00,
  margin_pct              NUMERIC(5,2)  NOT NULL DEFAULT 40.00,
  multiplier              NUMERIC(5,2)  GENERATED ALWAYS AS (1.0 / (1.0 - margin_pct / 100.0)) STORED,
  commission_pct          NUMERIC(5,2)  NOT NULL DEFAULT 0.00,
  bundle_discount_pct     NUMERIC(5,2)  NOT NULL DEFAULT 15.00,
  core_bundle_efficiency  NUMERIC(5,2)  NOT NULL DEFAULT 0.40,
  core_bundle_discount    NUMERIC(5,2)  NOT NULL DEFAULT 0.15,
  enterprise_multiplier   NUMERIC(5,2)  NOT NULL DEFAULT 1.35,
  is_active               BOOLEAN       NOT NULL DEFAULT FALSE,
  changed_by              UUID REFERENCES public.profiles(id),
  change_note             TEXT,
  created_at              TIMESTAMPTZ   NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ   NOT NULL DEFAULT now()
);

-- 2c. capability_categories
CREATE TABLE public.capability_categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT    NOT NULL,
  catalog     TEXT    NOT NULL CHECK (catalog IN ('general', 'insurance_core', 'insurance_secondary')),
  sort_order  INTEGER NOT NULL DEFAULT 0,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2d. capability_items
CREATE TABLE public.capability_items (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id  UUID NOT NULL REFERENCES public.capability_categories(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  description  TEXT,
  tier         TEXT CHECK (tier IN ('simple', 'medium', 'complex')),
  build_hours  NUMERIC(6,1) NOT NULL DEFAULT 0,
  monthly_hours NUMERIC(6,1) NOT NULL DEFAULT 0,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2e. dev_packages
CREATE TABLE public.dev_packages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT       NOT NULL,
  hours           INTEGER    NOT NULL DEFAULT 0,
  wholesale_price NUMERIC(10,2) NOT NULL,
  subtitle        TEXT,
  features        TEXT[]     NOT NULL DEFAULT '{}',
  is_featured     BOOLEAN    NOT NULL DEFAULT FALSE,
  sort_order      INTEGER    NOT NULL DEFAULT 0,
  is_active       BOOLEAN    NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2f. bundle_efficiency_tiers
CREATE TABLE public.bundle_efficiency_tiers (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  min_items      INTEGER      NOT NULL,
  max_items      INTEGER,
  efficiency_pct NUMERIC(5,2) NOT NULL,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 2g. saved_quotes
CREATE TABLE public.saved_quotes (
  id                           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                         TEXT NOT NULL,
  client_name                  TEXT,
  client_email                 TEXT,
  created_by                   UUID NOT NULL REFERENCES public.profiles(id),
  share_token                  TEXT UNIQUE DEFAULT encode(gen_random_bytes(16), 'hex'),
  config_snapshot              JSONB NOT NULL,
  selected_capabilities        UUID[] NOT NULL DEFAULT '{}',
  selected_insurance_core      UUID[] NOT NULL DEFAULT '{}',
  selected_insurance_secondary UUID[] NOT NULL DEFAULT '{}',
  selected_dev_package         UUID REFERENCES public.dev_packages(id),
  quote_type                   TEXT NOT NULL CHECK (quote_type IN ('single_item', 'custom_build', 'dev_package', 'offers')),
  single_build_hours           NUMERIC(6,1),
  single_monthly_hours         NUMERIC(6,1),
  total_setup_wholesale        NUMERIC(10,2),
  total_monthly_wholesale      NUMERIC(10,2),
  total_setup_client           NUMERIC(10,2),
  total_monthly_client         NUMERIC(10,2),
  notes                        TEXT,
  is_archived                  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ##########################################################
-- 2b. HELPER FUNCTIONS (after tables exist)
-- ##########################################################

-- Auto-update updated_at column
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Return the current user's role from profiles
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS TEXT AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid()
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- Create a profile row when a new auth user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''),
    COALESCE(NEW.raw_user_meta_data ->> 'role', 'client')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ##########################################################
-- 3. INDEXES
-- ##########################################################

-- profiles
CREATE INDEX idx_profiles_role  ON public.profiles (role);
CREATE INDEX idx_profiles_email ON public.profiles (email);

-- pricing_config
CREATE INDEX idx_pricing_config_is_active ON public.pricing_config (is_active) WHERE is_active = TRUE;
CREATE INDEX idx_pricing_config_created   ON public.pricing_config (created_at DESC);

-- capability_categories
CREATE INDEX idx_capability_categories_catalog_sort ON public.capability_categories (catalog, sort_order);

-- capability_items
CREATE INDEX idx_capability_items_cat_sort  ON public.capability_items (category_id, sort_order);
CREATE INDEX idx_capability_items_active    ON public.capability_items (is_active) WHERE is_active = TRUE;

-- dev_packages
CREATE INDEX idx_dev_packages_sort ON public.dev_packages (sort_order);

-- saved_quotes
CREATE INDEX idx_saved_quotes_created_by   ON public.saved_quotes (created_by, created_at DESC);
CREATE INDEX idx_saved_quotes_share_token  ON public.saved_quotes (share_token) WHERE share_token IS NOT NULL;
CREATE INDEX idx_saved_quotes_client_name  ON public.saved_quotes (client_name);


-- ##########################################################
-- 4. ROW LEVEL SECURITY (RLS)
-- ##########################################################

-- Enable RLS on every table
ALTER TABLE public.profiles                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pricing_config          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.capability_categories   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.capability_items        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_packages            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bundle_efficiency_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_quotes            ENABLE ROW LEVEL SECURITY;

-- ---- profiles ----
CREATE POLICY "Users read own profile"
  ON public.profiles FOR SELECT
  USING (id = auth.uid());

CREATE POLICY "Sales reads all profiles"
  ON public.profiles FOR SELECT
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales updates any profile"
  ON public.profiles FOR UPDATE
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Users update own profile"
  ON public.profiles FOR UPDATE
  USING (id = auth.uid());

-- ---- pricing_config ----
CREATE POLICY "Anyone reads active config"
  ON public.pricing_config FOR SELECT
  USING (is_active = TRUE);

CREATE POLICY "Sales reads all config history"
  ON public.pricing_config FOR SELECT
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales inserts new config"
  ON public.pricing_config FOR INSERT
  WITH CHECK (public.get_user_role() = 'sales');

CREATE POLICY "Sales updates config"
  ON public.pricing_config FOR UPDATE
  USING (public.get_user_role() = 'sales');

-- ---- capability_categories ----
CREATE POLICY "Anyone reads active categories"
  ON public.capability_categories FOR SELECT
  USING (is_active = TRUE);

CREATE POLICY "Sales reads all categories"
  ON public.capability_categories FOR SELECT
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages categories insert"
  ON public.capability_categories FOR INSERT
  WITH CHECK (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages categories update"
  ON public.capability_categories FOR UPDATE
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages categories delete"
  ON public.capability_categories FOR DELETE
  USING (public.get_user_role() = 'sales');

-- ---- capability_items ----
CREATE POLICY "Anyone reads active items"
  ON public.capability_items FOR SELECT
  USING (is_active = TRUE);

CREATE POLICY "Sales reads all items"
  ON public.capability_items FOR SELECT
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages items insert"
  ON public.capability_items FOR INSERT
  WITH CHECK (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages items update"
  ON public.capability_items FOR UPDATE
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages items delete"
  ON public.capability_items FOR DELETE
  USING (public.get_user_role() = 'sales');

-- ---- dev_packages ----
CREATE POLICY "Anyone reads active packages"
  ON public.dev_packages FOR SELECT
  USING (is_active = TRUE);

CREATE POLICY "Sales reads all packages"
  ON public.dev_packages FOR SELECT
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages packages insert"
  ON public.dev_packages FOR INSERT
  WITH CHECK (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages packages update"
  ON public.dev_packages FOR UPDATE
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages packages delete"
  ON public.dev_packages FOR DELETE
  USING (public.get_user_role() = 'sales');

-- ---- bundle_efficiency_tiers ----
CREATE POLICY "Anyone reads tiers"
  ON public.bundle_efficiency_tiers FOR SELECT
  USING (TRUE);

CREATE POLICY "Sales manages tiers insert"
  ON public.bundle_efficiency_tiers FOR INSERT
  WITH CHECK (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages tiers update"
  ON public.bundle_efficiency_tiers FOR UPDATE
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales manages tiers delete"
  ON public.bundle_efficiency_tiers FOR DELETE
  USING (public.get_user_role() = 'sales');

-- ---- saved_quotes ----
CREATE POLICY "Sales reads all quotes"
  ON public.saved_quotes FOR SELECT
  USING (public.get_user_role() = 'sales');

CREATE POLICY "Sales creates quotes"
  ON public.saved_quotes FOR INSERT
  WITH CHECK (public.get_user_role() = 'sales');

CREATE POLICY "Sales updates own quotes"
  ON public.saved_quotes FOR UPDATE
  USING (public.get_user_role() = 'sales' AND created_by = auth.uid());


-- ##########################################################
-- 5. RPC FUNCTIONS
-- ##########################################################

-- save_pricing_config: deactivate current, insert new active row
CREATE OR REPLACE FUNCTION public.save_pricing_config(
  p_dev_rate                NUMERIC,
  p_margin_pct              NUMERIC,
  p_commission_pct          NUMERIC,
  p_bundle_discount_pct     NUMERIC,
  p_core_bundle_efficiency  NUMERIC,
  p_core_bundle_discount    NUMERIC,
  p_enterprise_multiplier   NUMERIC,
  p_change_note             TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_new_id UUID;
BEGIN
  -- Deactivate current active config
  UPDATE public.pricing_config
     SET is_active = FALSE,
         updated_at = now()
   WHERE is_active = TRUE;

  -- Insert new active config
  INSERT INTO public.pricing_config (
    dev_rate,
    margin_pct,
    commission_pct,
    bundle_discount_pct,
    core_bundle_efficiency,
    core_bundle_discount,
    enterprise_multiplier,
    is_active,
    changed_by,
    change_note
  ) VALUES (
    p_dev_rate,
    p_margin_pct,
    p_commission_pct,
    p_bundle_discount_pct,
    p_core_bundle_efficiency,
    p_core_bundle_discount,
    p_enterprise_multiplier,
    TRUE,
    auth.uid(),
    p_change_note
  )
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- get_quote_by_token: anonymous-safe lookup of a shared quote
CREATE OR REPLACE FUNCTION public.get_quote_by_token(p_token TEXT)
RETURNS JSONB AS $$
  SELECT to_jsonb(sq.*)
    FROM public.saved_quotes sq
   WHERE sq.share_token = p_token
     AND sq.is_archived = FALSE
   LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ##########################################################
-- 6. TRIGGERS
-- ##########################################################

-- updated_at auto-update triggers
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_pricing_config_updated_at
  BEFORE UPDATE ON public.pricing_config
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_capability_categories_updated_at
  BEFORE UPDATE ON public.capability_categories
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_capability_items_updated_at
  BEFORE UPDATE ON public.capability_items
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_dev_packages_updated_at
  BEFORE UPDATE ON public.dev_packages
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_saved_quotes_updated_at
  BEFORE UPDATE ON public.saved_quotes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- Profile creation on signup
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ##########################################################
-- 7. SEED DATA
-- ##########################################################

-- 7a. Initial pricing config
INSERT INTO public.pricing_config (
  dev_rate, margin_pct, commission_pct, bundle_discount_pct,
  core_bundle_efficiency, core_bundle_discount, enterprise_multiplier,
  is_active, change_note
) VALUES (
  105.00, 40.00, 0.00, 15.00,
  0.40, 0.15, 1.35,
  TRUE, 'Initial config from hardcoded defaults'
);

-- 7b. Bundle efficiency tiers
INSERT INTO public.bundle_efficiency_tiers (min_items, max_items, efficiency_pct) VALUES
  (1,  1,    0.00),
  (2,  3,    0.08),
  (4,  6,    0.12),
  (7,  10,   0.15),
  (11, NULL, 0.18);

-- 7c. Dev packages
INSERT INTO public.dev_packages (name, hours, wholesale_price, subtitle, features, is_featured, sort_order) VALUES
  (
    'Core',
    10,
    500.00,
    NULL,
    ARRAY[
      '10 dev hours / month',
      'Bug fixes & minor tweaks',
      'Monthly performance review',
      'Email support',
      'No rollover'
    ],
    FALSE,
    1
  ),
  (
    'Plus',
    25,
    1500.00,
    NULL,
    ARRAY[
      '25 dev hours / month',
      'New feature builds',
      'Workflow optimization',
      'Priority Slack support',
      'Weekly check-in call',
      'No rollover'
    ],
    TRUE,
    2
  ),
  (
    'Custom',
    0,
    2500.00,
    NULL,
    ARRAY[
      'Custom hour allocation',
      'Dedicated dev resource',
      'Strategic planning sessions',
      'Priority Slack + phone support',
      'Custom SLA',
      'Contact us to scope'
    ],
    FALSE,
    3
  );

-- 7d. Capability categories & items
-- We use DO $$ blocks so we can store generated category UUIDs in variables.

DO $$
DECLARE
  cat_lead_capture          UUID;
  cat_ai_outreach           UUID;
  cat_appointment           UUID;
  cat_crm                   UUID;
  cat_lead_qual             UUID;
  cat_followup              UUID;
  cat_reviews               UUID;
  cat_client_ops            UUID;
  cat_retention             UUID;
  cat_analytics             UUID;
  cat_content               UUID;
  cat_ai_productivity       UUID;
  cat_compliance            UUID;
  cat_custom_eng            UUID;
  cat_website               UUID;
  cat_training              UUID;
  cat_ins_core              UUID;
  cat_ins_secondary         UUID;
BEGIN

  -- =========================================================
  -- GENERAL CATEGORIES (16)
  -- =========================================================

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Lead Capture & Instant Response', 'general', 1)
  RETURNING id INTO cat_lead_capture;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('AI-Powered Outreach', 'general', 2)
  RETURNING id INTO cat_ai_outreach;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Appointment Booking & Scheduling', 'general', 3)
  RETURNING id INTO cat_appointment;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('CRM Pipelines & Infrastructure', 'general', 4)
  RETURNING id INTO cat_crm;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Lead Qualification & Scoring', 'general', 5)
  RETURNING id INTO cat_lead_qual;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Follow-Up Nurture & Conversion', 'general', 6)
  RETURNING id INTO cat_followup;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Reviews Referrals & Reputation', 'general', 7)
  RETURNING id INTO cat_reviews;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Client & Customer Operations', 'general', 8)
  RETURNING id INTO cat_client_ops;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Retention Reactivation & LTV', 'general', 9)
  RETURNING id INTO cat_retention;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Analytics Dashboards & Intelligence', 'general', 10)
  RETURNING id INTO cat_analytics;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Content & Communication Automation', 'general', 11)
  RETURNING id INTO cat_content;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('AI Productivity & Internal Operations', 'general', 12)
  RETURNING id INTO cat_ai_productivity;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Compliance & Secure Workflows', 'general', 13)
  RETURNING id INTO cat_compliance;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Custom Engineering & Integrations', 'general', 14)
  RETURNING id INTO cat_custom_eng;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Website Development', 'general', 15)
  RETURNING id INTO cat_website;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Training Support & Optimization', 'general', 16)
  RETURNING id INTO cat_training;

  -- =========================================================
  -- INSURANCE CATEGORIES (2)
  -- =========================================================

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Insurance Core Operations', 'insurance_core', 1)
  RETURNING id INTO cat_ins_core;

  INSERT INTO public.capability_categories (name, catalog, sort_order)
  VALUES ('Insurance Growth & Intelligence', 'insurance_secondary', 1)
  RETURNING id INTO cat_ins_secondary;

  -- =========================================================
  -- GENERAL CAPABILITY ITEMS (84 total)
  -- =========================================================

  -- Cat 1: Lead Capture & Instant Response (7 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_lead_capture, 'AI voice agent inbound calls 24/7',        'AI-powered phone agent answers every call, qualifies leads, and routes to the right team',      'complex', 5, 2,   1),
    (cat_lead_capture, 'Missed-call text-back',                     'Automatically texts anyone whose call was missed within seconds',                              'simple',  2, 1,   2),
    (cat_lead_capture, 'Website chat widget with SMS follow-up',    'Live chat on your site that captures info and continues the conversation via SMS',              'medium',  3, 1.5, 3),
    (cat_lead_capture, 'AI chatbot for websites and listings',      'Intelligent chatbot trained on your business to engage and qualify visitors',                   'medium',  3, 1.5, 4),
    (cat_lead_capture, 'After-hours inquiry handling',              'Captures and responds to leads that come in outside business hours',                            'simple',  2, 1,   5),
    (cat_lead_capture, 'Instant lead response <2 min',             'Triggers immediate outreach the moment a new lead comes in',                                    'simple',  2, 1,   6),
    (cat_lead_capture, 'Quote request handling automation',         'Collects quote details, routes to the right person, and follows up automatically',              'medium',  3, 1.5, 7);

  -- Cat 2: AI-Powered Outreach (7 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_ai_outreach, 'AI cold email outreach campaigns',          'Automated cold email sequences with AI personalization at scale',                                'complex', 5, 2,   1),
    (cat_ai_outreach, 'AI personalized message generation',        'AI writes unique, relevant messages for each prospect based on their profile',                   'medium',  3, 1.5, 2),
    (cat_ai_outreach, 'Automated LinkedIn outreach sequences',     'Multi-step LinkedIn connection and messaging campaigns on autopilot',                            'complex', 5, 2,   3),
    (cat_ai_outreach, 'Lead list building & enrichment',           'Builds targeted prospect lists and enriches them with contact and company data',                 'medium',  3, 1.5, 4),
    (cat_ai_outreach, 'Multi-channel outbound campaigns',          'Coordinated outreach across email, LinkedIn, SMS, and phone',                                   'complex', 5, 2,   5),
    (cat_ai_outreach, 'AI reply handling & conversation routing',  'AI reads replies, classifies intent, and routes hot leads to your team',                         'medium',  3, 1.5, 6),
    (cat_ai_outreach, 'Outreach performance analytics',            'Tracks open rates, reply rates, and conversions across all outreach channels',                   'medium',  3, 1.5, 7);

  -- Cat 3: Appointment Booking & Scheduling (6 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_appointment, 'Automated appointment booking system',      'Self-service booking linked to your calendar with automatic confirmations',                      'complex', 5, 2,   1),
    (cat_appointment, 'Calendar + CRM integration',                'Syncs appointments between your calendar and CRM so nothing falls through',                      'medium',  3, 1.5, 2),
    (cat_appointment, 'Smart appointment confirmations',           'Sends confirmation and reminder messages via SMS and email',                                     'simple',  2, 1,   3),
    (cat_appointment, 'AI scheduling optimization',                'AI suggests optimal appointment times based on availability and travel',                          'medium',  3, 1.5, 4),
    (cat_appointment, 'Consultation booking automation',           'Dedicated booking flow for consultations with intake forms and prep materials',                   'medium',  3, 1.5, 5),
    (cat_appointment, 'Automatic rebooking workflows',             'Automatically offers new time slots when appointments are cancelled',                             'simple',  2, 1,   6);

  -- Cat 4: CRM Pipelines & Infrastructure (6 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_crm, 'CRM setup and configuration',                      'Full CRM buildout with custom fields, stages, and automation rules',                              'complex', 5, 2,   1),
    (cat_crm, 'Custom pipeline creation',                          'Builds sales pipelines tailored to your specific deal flow and process',                          'medium',  3, 1.5, 2),
    (cat_crm, 'Lead tracking and status automation',               'Automatically moves leads through stages based on their actions and responses',                   'medium',  3, 1.5, 3),
    (cat_crm, 'CRM + calendar integration',                        'Connects your CRM to calendars so meetings auto-log to contact records',                         'simple',  2, 1,   4),
    (cat_crm, 'Multi-location CRM coordination',                   'Unified CRM setup across multiple locations with proper routing and visibility',                  'complex', 5, 2,   5),
    (cat_crm, 'White-label client portal setup',                   'Branded portal where your clients can log in, view progress, and communicate',                    'complex', 5, 2,   6);

  -- Cat 5: Lead Qualification & Scoring (5 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_lead_qual, 'AI lead qualification workflows',             'AI evaluates leads based on fit criteria and flags the best opportunities',                       'medium',  3, 1.5, 1),
    (cat_lead_qual, 'Paid-ad lead filtering',                      'Filters and scores leads from paid campaigns to focus on high-quality prospects',                 'medium',  3, 1.5, 2),
    (cat_lead_qual, 'Lead scoring and prioritization',             'Assigns scores to leads so your team works the hottest opportunities first',                      'medium',  3, 1.5, 3),
    (cat_lead_qual, 'Client segmentation logic',                   'Groups contacts by behavior, value, or profile for targeted communication',                       'medium',  3, 1.5, 4),
    (cat_lead_qual, 'Client health scoring',                       'Monitors engagement signals to flag at-risk clients before they churn',                            'complex', 5, 2,   5);

  -- Cat 6: Follow-Up Nurture & Conversion (8 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_followup, 'Email nurture sequences',                      'Drip email campaigns that warm leads over time with valuable content',                             'simple',  2, 1,   1),
    (cat_followup, 'SMS nurture sequences',                        'Text message follow-up series for faster, more personal engagement',                               'simple',  2, 1,   2),
    (cat_followup, 'Voice + SMS + email multi-channel campaigns',  'Coordinated follow-up across phone, text, and email for maximum reach',                            'complex', 5, 2,   3),
    (cat_followup, 'Smart estimate follow-up',                     'Automated check-ins after sending estimates to keep deals moving',                                  'medium',  3, 1.5, 4),
    (cat_followup, 'Quote follow-up sequences',                    'Multi-step follow-up after quotes are sent until a decision is made',                               'medium',  3, 1.5, 5),
    (cat_followup, 'Lost quote recovery',                          'Re-engages prospects who received quotes but went cold',                                            'medium',  3, 1.5, 6),
    (cat_followup, 'No-show prevention',                           'Pre-appointment reminders and confirmations to reduce no-shows',                                    'simple',  2, 1,   7),
    (cat_followup, 'Appointment reminder automation',              'Scheduled reminders via SMS and email before upcoming appointments',                                 'simple',  2, 1,   8);

  -- Cat 7: Reviews Referrals & Reputation (4 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_reviews, 'Review request automation',                     'Asks happy customers for reviews at the right moment via SMS or email',                              'simple',  2, 1,   1),
    (cat_reviews, 'Review generation workflows',                   'Multi-step campaign to maximize Google/Yelp review collection',                                     'simple',  2, 1,   2),
    (cat_reviews, 'Referral request automation',                   'Systematically asks satisfied clients for referrals with easy sharing links',                        'simple',  2, 1,   3),
    (cat_reviews, 'Systematic referral engines',                   'Full referral program with tracking, rewards, and automated follow-up',                              'medium',  3, 1.5, 4);

  -- Cat 8: Client & Customer Operations (5 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_client_ops, 'Digital intake form automation',             'Online forms that collect client info and feed directly into your systems',                           'simple',  2, 1,   1),
    (cat_client_ops, 'Smart onboarding workflows',                 'Guided onboarding sequence that walks new clients through setup steps',                              'medium',  3, 1.5, 2),
    (cat_client_ops, 'Maintenance ticket automation',              'Ticket creation, routing, and status updates handled automatically',                                  'medium',  3, 1.5, 3),
    (cat_client_ops, 'Issue resolution workflows',                 'Automated triage and escalation paths to resolve client issues faster',                               'medium',  3, 1.5, 4),
    (cat_client_ops, 'Pre-consultation education sequences',       'Sends prep materials and expectations before consultations',                                          'simple',  2, 1,   5);

  -- Cat 9: Retention Reactivation & LTV (7 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_retention, 'Customer reactivation campaigns',             'Win-back campaigns targeting inactive customers with personalized offers',                            'medium',  3, 1.5, 1),
    (cat_retention, 'Renewal reminder automation',                 'Proactive reminders before contracts or subscriptions expire',                                        'simple',  2, 1,   2),
    (cat_retention, 'Churn prediction systems',                    'AI monitors engagement patterns to predict which clients may leave',                                   'complex', 5, 2,   3),
    (cat_retention, 'Churn prevention automation',                 'Triggered outreach and offers when churn risk is detected',                                            'medium',  3, 1.5, 4),
    (cat_retention, 'Upsell automation',                           'Identifies and presents relevant upgrade opportunities to existing clients',                           'medium',  3, 1.5, 5),
    (cat_retention, 'Cross-sell automation',                       'Recommends complementary services based on what the client already uses',                               'medium',  3, 1.5, 6),
    (cat_retention, 'Lifetime value optimization',                 'Data-driven strategies to maximize revenue per client over time',                                       'complex', 5, 2,   7);

  -- Cat 10: Analytics Dashboards & Intelligence (5 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_analytics, 'Monthly performance reporting',               'Automated monthly reports covering KPIs, trends, and recommendations',                                'medium',  3, 1.5, 1),
    (cat_analytics, 'Real-time dashboards',                        'Live dashboards showing pipeline, revenue, and team performance',                                     'complex', 5, 2,   2),
    (cat_analytics, 'Revenue forecasting dashboards',              'Predictive views of expected revenue based on pipeline and trends',                                    'complex', 5, 2,   3),
    (cat_analytics, 'Multi-location performance dashboards',       'Comparative dashboards across all locations for executive visibility',                                  'complex', 5, 2,   4),
    (cat_analytics, 'Predictive analytics & forecasting',          'AI-powered forecasting for demand, revenue, and resource planning',                                    'complex', 5, 2,   5);

  -- Cat 11: Content & Communication Automation (5 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_content, 'AI-generated email content',                    'AI writes professional email content tailored to your audience and brand',                              'simple',  2, 1,   1),
    (cat_content, 'AI-generated SMS content',                      'AI creates concise, engaging text messages for campaigns and follow-ups',                               'simple',  2, 1,   2),
    (cat_content, 'AI-generated social content',                   'AI produces social media posts, captions, and content calendars',                                       'medium',  3, 1.5, 3),
    (cat_content, 'AI-generated newsletters',                      'Automated newsletter creation with curated content and personalization',                                 'medium',  3, 1.5, 4),
    (cat_content, 'Pre-sale education workflows',                  'Educational content sequences that warm prospects before the sales call',                                'simple',  2, 1,   5);

  -- Cat 12: AI Productivity & Internal Operations (3 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_ai_productivity, 'AI meeting summaries',                  'Automatic meeting notes, key decisions, and action items after every call',                              'simple',  2, 1,   1),
    (cat_ai_productivity, 'Automated action-item extraction',      'Pulls action items from meetings and assigns them to the right people',                                  'simple',  2, 1,   2),
    (cat_ai_productivity, 'Internal task automation',              'Automates repetitive internal tasks like data entry, notifications, and approvals',                       'medium',  3, 1.5, 3);

  -- Cat 13: Compliance & Secure Workflows (3 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_compliance, 'Compliance-friendly workflow design',        'Workflows built with regulatory requirements and audit trails in mind',                                   'medium',  3, 1.5, 1),
    (cat_compliance, 'HIPAA-compliant automation design',          'Healthcare-grade automation with proper data handling and access controls',                                'complex', 5, 2,   2),
    (cat_compliance, 'Secure data handling workflows',             'Encrypted data flows with access controls and secure storage practices',                                   'medium',  3, 1.5, 3);

  -- Cat 14: Custom Engineering & Integrations (3 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_custom_eng, 'Custom software integrations',               'Connects your existing tools and platforms into a unified workflow',                                       'complex', 5, 2,   1),
    (cat_custom_eng, 'Custom automation logic builds',             'Bespoke automation logic tailored to your unique business processes',                                       'complex', 5, 2,   2),
    (cat_custom_eng, 'API-based workflow automation',              'Builds custom API connections between systems for seamless data flow',                                      'complex', 5, 2,   3);

  -- Cat 15: Website Development (4 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_website, 'Homepage with integrations & AI chat',          'Full homepage build including design, copy, integrations, and AI chatbot setup',                             'complex', 6, 1,   1),
    (cat_website, 'Additional website page',                       'Extra page with custom layout, copy creation, and responsive design',                                        'medium',  3, 1,   2),
    (cat_website, 'Website copy creation',                         'Professional copywriting for all website pages — messaging, CTAs, and brand voice',                          'medium',  3, 1.5, 3),
    (cat_website, 'AI chatbot / bot integration',                  'Intelligent AI chat widget trained on your business for 24/7 visitor engagement',                            'complex', 3, 1.5, 4);

  -- Cat 16: Training Support & Optimization (6 items)
  INSERT INTO public.capability_items (category_id, name, description, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_training, 'Team onboarding and training',                 'Live training sessions to get your team fully up to speed on all automations',                               'medium',  3, 0,   1),
    (cat_training, 'System training documentation',                'Step-by-step guides and SOPs for every automation in your stack',                                             'simple',  2, 0,   2),
    (cat_training, 'Ongoing system optimization',                  'Continuous tuning and improvements based on performance data',                                                'simple',  0, 1,   3),
    (cat_training, 'Weekly optimization sessions',                 'Regular strategy calls to review results and plan next optimizations',                                         'simple',  0, 1,   4),
    (cat_training, 'Dedicated manager support',                    'A dedicated account manager for proactive support and strategic guidance',                                     'medium',  0, 1.5, 5),
    (cat_training, 'Priority Slack and email support',             'Fast-response support channel for urgent issues and questions',                                                'simple',  0, 1,   6);

  -- =========================================================
  -- INSURANCE CORE ITEMS (9 items)
  -- =========================================================
  INSERT INTO public.capability_items (category_id, name, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_ins_core, 'Speed-to-lead automation (web forms, email, SMS)',           NULL, 3, 1.5, 1),
    (cat_ins_core, 'Automated intake & routing to producer / service team',      NULL, 3, 1.5, 2),
    (cat_ins_core, 'Follow-up sequences (multi-touch, no fallthrough)',          NULL, 3, 1.5, 3),
    (cat_ins_core, 'After-hours / overflow voice agent (optional add-on)',       NULL, 5, 2,   4),
    (cat_ins_core, 'Service request triage (COIs, endorsements, renewals)',      NULL, 3, 1,   5),
    (cat_ins_core, 'CRM setup + pipeline configuration',                         NULL, 5, 1,   6),
    (cat_ins_core, 'Owner visibility dashboard (response speed, follow-up)',     NULL, 5, 1.5, 7),
    (cat_ins_core, 'Onboarding, training & documentation',                       NULL, 3, 0,   8),
    (cat_ins_core, 'Ongoing optimization + priority support',                    NULL, 0, 2,   9);

  -- =========================================================
  -- INSURANCE SECONDARY ITEMS (6 items)
  -- =========================================================
  INSERT INTO public.capability_items (category_id, name, tier, build_hours, monthly_hours, sort_order) VALUES
    (cat_ins_secondary, 'High-intent lead sourcing setup & vendor integration',  NULL, 3, 1,   1),
    (cat_ins_secondary, 'Demand intelligence for ads & outreach',                NULL, 3, 1.5, 2),
    (cat_ins_secondary, 'Lead ROI clarity dashboard (source to conversion)',      NULL, 5, 1.5, 3),
    (cat_ins_secondary, 'Missed-opportunity reactivation campaigns',             NULL, 3, 1.5, 4),
    (cat_ins_secondary, 'Owner-level performance dashboards',                    NULL, 5, 1.5, 5),
    (cat_ins_secondary, 'Safe scaling optimization workflows',                   NULL, 3, 1,   6);

END $$;
